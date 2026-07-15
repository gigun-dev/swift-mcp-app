# 01 — AppsBridge 設計(iOS/WKWebView 向け MCP Apps ホストブリッジ)

> 2026-07-15 起票。P2 スパイクの設計図。実装前の設計文書であり、
> スパイクで判明した事実は「> 日付 更新:」で積層する(caldav docs/modeling の流儀)。
>
> 一次資料(すべてローカルで確認済み。行番号は 2026-07-15 時点のチェックアウト):
> - 規範仕様: `~/ghq/github.com/modelcontextprotocol/ext-apps/specification/2026-01-26/apps.mdx`
> - メッセージ型の正: 同 `src/spec.types.ts`
> - ホスト参照実装: 同 `src/app-bridge.ts` / `src/message-transport.ts` / `examples/basic-host/src/implementation.ts`
> - View 側(対向): 同 `src/app.ts`、caldav `src/presentation/mcp/ui/todos-entry.ts`
> - 消費対象サーバー: caldav `src/presentation/mcp/server.ts`(registerAppResource/registerAppTool)
> - 既存: `Sources/Services/MCP/MCPConnection.swift`(swift-sdk 0.12.1 Client)

## 0. 全体像(何を作るか)

Web ホストの三者構成(Host ⇔ Sandbox proxy iframe ⇔ View iframe)に対し、iOS では
**WKWebView 自体が Sandbox の外殻**になる。仕様上も sandbox proxy は「ホストが Web ページの
場合」の MUST であり(apps.mdx:472「If the Host is a web page, it MUST wrap the View
and communicate with it through an intermediate Sandbox proxy」)、ネイティブホストは
`sandbox-proxy-ready` / `sandbox-resource-ready` の往復を**丸ごと省略してよい**。
HTML は `resources/read` で取得してホストが直接 `loadHTMLString` する。

```
View(caldav todos-entry バンドル / ext-apps App)
  │ JSON-RPC 2.0 over postMessage(window.parent === window)
  ▼
[WKUserScript インターセプタ]───WKScriptMessageHandler───┐
  ▲                                                       ▼
[evaluateJavaScript で MessageEvent 合成] ◀── AppsBridgeSession(actor・Services)
                                                          │ tools/call / resources/read を素通しプロキシ
                                                          ▼
                                              swift-sdk Client(MCPConnection)── caldav /mcp
```

レイヤー配置(CLAUDE.md アーキテクチャ方針に従う):

```
Sources/Kernel/AppsProtocol/     # JSON-RPC 封筒・ui/* メッセージの Codable・JSONValue(純粋・UI/WebKit 非依存)
Sources/Services/AppsBridge/     # AppsBridgeSession(状態機械)・WebViewTransport(WKWebView 仲介)・リソースキャッシュ
Sources/Features/AppCard/        # AppCardView(UIViewRepresentable)+ チャット内インライン配置
```

ブリッジは caldav 非依存(ツール名・structuredContent の形を一切知らない。
知るのは ext-apps プロトコルと `_meta.ui.*` だけ)。

---

## 1. JSON-RPC over postMessage の WKWebView 実装(最大リスク論点)

### 前提事実(一次資料の裏取り)

- View 側の送受信は `PostMessageTransport` に固定されている。
  `App.connect()` は引数省略時に `new PostMessageTransport(window.parent, window.parent)`
  を生成する(app.ts:1943-1946)。caldav の todos-entry は `await app.connect()` と
  **引数なし**で呼んでいる(todos-entry.ts:2508)→ 対向はこのデフォルト経路で確定。
- 送信: `this.eventTarget.postMessage(message, "*")`(message-transport.ts:132)。
  eventTarget = `window.parent`。
- 受信: `window.addEventListener("message", ...)` で、
  `event.source !== this.eventSource` なら無視(message-transport.ts:77-81)。
  eventSource も `window.parent`。JSON-RPC でないメッセージは黙って無視、
  `jsonrpc:"2.0"` を持つが malformed なものだけ onerror(同:86-103)。
  zod の safeParse は既定 strip なので**未知キーが混ざっても壊れない**。

### 決定的な観察: WKWebView 主フレームでは `window.parent === window`

iframe に入れずに `loadHTMLString` した HTML では、HTML 仕様により主フレームの
`window.parent` は自分自身。したがって View の送信は実質
`window.postMessage(msg, "*")`(自分宛て・本物のイベント・`event.source === window`)、
View の受信フィルタは「`event.source === window` なら通す」になる。
**View バンドルを1バイトも書き換えずに、この2性質だけで双方向を成立させられる。**

### 決定: `isTrusted` 判別方式のインターセプタ(documentStart 注入)

WKUserScript(injectionTime: `.atDocumentStart`, forMainFrameOnly: true)で
ページのどのスクリプトよりも先に capture リスナーを登録する:

```js
// (概念コード — 実装時はこの設計の写経元としてコメントで本節を参照すること)
window.addEventListener("message", (event) => {
  const d = event.data;
  if (!d || d.jsonrpc !== "2.0") return;            // 無関係なイベントは素通し
  if (event.source !== window) return;               // 自フレーム由来のみ対象
  if (event.isTrusted) {                             // View→Host(本物の postMessage)
    window.webkit.messageHandlers.appsBridge.postMessage(JSON.stringify(d));
    event.stopImmediatePropagation();                // View 自身のリスナーに返さない
  }
  // isTrusted === false はホストが合成した Host→View 配送 → 素通しで View に届く
}, true);
```

- **View→Host**: View の `window.parent.postMessage(msg,"*")` は本物のイベント
  (`isTrusted === true`)としてキューされる。インターセプタが先に受けて
  `WKScriptMessageHandler` へ転送し、`stopImmediatePropagation()` で
  View 自身の transport リスナーへのループバック(自分の送信を自分で受ける事故)を止める。
  documentStart 注入 = 登録順が常に最初、が成立条件。
- **Host→View**: Swift 側から `evaluateJavaScript` で
  `window.dispatchEvent(new MessageEvent("message", { data: msg, source: window, origin: "" }))`
  を実行する。`dispatchEvent` 由来の合成イベントは DOM 仕様により **必ず `isTrusted === false`**
  (ここが判別の根拠。UA 実装依存ではなく仕様保証)。`source: window` は正当な
  WindowProxy なので MessageEvent コンストラクタの型制約
  (`MessageEventSource = WindowProxy|MessagePort|ServiceWorker`)を満たし、かつ
  View の `event.source !== eventSource`(= window)チェックを自然に通過する。
- **Swift→JS の値渡し**: 文字列連結で JS を組み立てるとエスケープ事故(injection)の温床。
  `callAsyncJavaScript("__appsBridgeDeliver(msg)", arguments: ["msg": jsonString], ...)`
  で WebKit のネイティブ直列化に載せる。`__appsBridgeDeliver(jsonString)` は
  documentStart スクリプト内で `JSON.parse` → `dispatchEvent` する配送関数として定義。

### スパイクでの世界(WKContentWorld)の扱い

理想は インターセプタ+`messageHandlers.appsBridge` を専用 `WKContentWorld` に置き、
View の JS からハンドラ直叩き・配送関数改竄をできなくすること(DOM イベントは
world をまたいで見えるので傍受自体は成立するはず)。ただし
**world をまたいだ `stopImmediatePropagation` の効き方は文書化が薄く、スパイクの
不確実性を増やす**。→ **スパイクは `.page` world で実施**(コンテンツはホストが
自分で load した単一 HTML であり、ハンドラ露出のリスクは「View が自分の transport を
バイパスできる」程度)。world 分離は P3 の堅牢化項目として起票。

### ボツ案

- **`window.parent` を差し替える(fake parent オブジェクト代入)**:
  `parent` は HTML 仕様の [Replaceable] なので代入自体は可能。だが受信側で
  `event.source !== eventSource`(= fake object)を通すには MessageEvent の
  `source` に任意オブジェクトを入れる必要があり、IDL 型制約で **TypeError**。
  受信経路が成立しない。送信だけ差し替え・受信は別手段、という半端な構成になるので却下。
- **View バンドル側に WKWebView 用 transport を実装(caldav 側改修)**:
  「ブリッジは caldav 非依存・任意の MCP Apps サーバーを表示する」路線Bの
  コア価値に反する。他サーバー(ext-apps examples)がそのまま動かなくなる。却下。
- **`window.webkit.messageHandlers` を View に直接使わせる**: 同上+仕様外。却下。
- **タグ付きメッセージ(`{__fromHost:true}` を混ぜる)で方向判別**: postMessage は
  構造化クローンでタグが残り、zod strip で害はないが、プロトコル外のキーを
  ワイヤに流すのは監査性が悪い。`isTrusted` が仕様保証で使える以上不要。却下。

### 「あとで変更するコスト」評価

インターセプタは1ファイルの JS 文字列 + Swift 側配送関数の2点に閉じる。
world 分離・タグ方式への切替はどれも局所変更で**可逆**。ここで凝らずに最短で通す。

---

## 2. ライフサイクル状態機械

仕様の順序制約(apps.mdx:485): View→`ui/initialize`(request)→ Host が
hostContext 入り result を返す → View→`ui/notifications/initialized` →
**それまで Host は View にいかなる request/notification も送ってはならない(MUST NOT)**。
破棄前は Host→`ui/resource-teardown`(request)(app-bridge.ts:811-827)。

### 決定: `actor AppsBridgeSession`(Services)+ 状態 enum + 送信キュー

```swift
// Sources/Services/AppsBridge/AppsBridgeSession.swift(輪郭)
actor AppsBridgeSession {
  enum State {
    case loadingResource          // resources/read 中(HTML 未ロード)
    case awaitingInitialize       // HTML ロード済み・ui/initialize 待ち
    case ready(AppCapabilities)   // initialized 受信済み — 送信キューを flush
    case tearingDown              // resource-teardown 送信済み・応答待ち(タイムアウト付き)
    case closed
  }
  private var state: State
  private var outbox: [HostToViewMessage] = []   // ready 前の tool-input/tool-result を貯める

  // Host→View API(basic-host implementation.ts:229/235 と同名の語彙)
  func sendToolInput(arguments: JSONValue)
  func sendToolResult(_ raw: JSONValue)          // CallToolResult は素通し(§3)
  func sendToolCancelled(reason: String)
  func setHostContext(_ patch: HostContextPatch) // ui/notifications/host-context-changed
  func teardown() async                          // タイムアウト(例 2s)後は強制 close

  // View→Host のディスパッチ(WebViewTransport から呼ばれる)
  func handleIncoming(_ message: JSONRPCMessage) async
}
```

- **1 セッション = 1 WKWebView = 1 ツールカード**。チャット内に複数カードが並ぶ前提で、
  セッションは接続(MCPConnection)を共有しつつ独立に生成・破棄される。
- basic-host と同じく、`tools/call` の結果 promise と HTML プリフェッチを並走させ、
  initialized 到達後に `tool-input` → 結果到着後 `tool-result`(失敗時 `tool-cancelled`)
  の順で流す(implementation.ts:202-244 が正)。ready 前に届いた分は outbox に積み、
  ready 遷移時に FIFO で flush(仕様の MUST NOT を機械的に守る)。
- View→Host request のうち `tools/call` / `resources/read` は状態を持たない素通し
  プロキシ(§3)。`ui/initialize` と `ping` だけが状態機械に触る
  (app-bridge.ts:401-405 と同じ分離)。
- 未知メソッド: request には JSON-RPC error `-32601`、notification はログのみ
  (transport が「未知は黙殺」規約なのと対称)。

ボツ案: Combine/AsyncStream ベースのイベントバス化 — スパイクには過剰。
actor 1 個 + enum が最小で、後からストリーム化するのは可逆。

---

## 3. Kernel のメッセージ型 Codable 設計

### 決定: 「ui/* は最小集合を型で写経、MCP 素通し系(tools/call 等)は JSONValue パススルー」

spec.types.ts は約 30 型あるが、全写経はスパイクの敵。かつ **ブリッジの本質は
プロキシ**であり、`tools/call` の params / `CallToolResult` をデコード→再エンコード
すると未知フィールド(`_meta`、structuredContent の拡張)を落とす危険がある。
そこで:

1. **JSON-RPC 封筒**(`JSONRPCRequest/Response/Notification` + `RequestID` + `JSONValue`)
   を Kernel に置く。swift-sdk の `Value` 型が再利用できればそれを typealias、
   できなければ自前 `JSONValue`(indirect enum)。※swift-sdk の型は public だが
   モジュール境界の都合を実装時に確認。
2. **型で写経する ui/* メッセージ(スパイク最小集合)** — 出典は spec.types.ts の行:
   - `ui/initialize` Request/Result(:554/:570)— Result の `hostContext` は
     theme / locale / displayMode / containerDimensions / availableDisplayModes のみ
     (styles.variables は P3。省略はプロトコル上合法)
   - `ui/notifications/initialized`(:590)、`appCapabilities`(:492 周辺)は
     受けた JSON を保持するだけ(解釈しない)
   - `ui/notifications/tool-input`(:278)/ `tool-result`(:300, params = CallToolResult
     → **JSONValue のまま**)/ `tool-cancelled`(:311)
   - `ui/notifications/size-changed`(:265)
   - `ui/resource-teardown` Request/Result(:446/:455)
   - `ui/notifications/host-context-changed`(:414)— width 変化通知に必要(§5)
   - `ui/open-link`(:150)— 実装1行(`UIApplication.open`)で済み、todos カードの
     リンクを殺さないため最小集合に含める
3. **素通し(型なし・method 文字列でルーティング)**: `tools/call`, `resources/read`,
   `ping`。将来 `ui/message` / `ui/update-model-context` / `ui/request-display-mode` /
   `notifications/message`(logging)を足す拡張点として、
   `enum IncomingViewMessage { case typed(...), case passthrough(method: String, ...) }`
   の2レーン構造にしておく。

method 定数は spec.types.ts:814-843 の `*_METHOD` 定数群から写経し、各定数に
出典行コメントを付ける(CLAUDE.md「写経した契約には出典を残す」)。

ボツ案: 全型写経(コード生成含む)— 型の 2/3 はスパイクで使わず、spec 改版時の
追従コストだけ増える。足すのは可逆・削るのは面倒、なので最小から始める。
ボツ案: `tool-result` を swift-sdk の `CallTool.Result` に型付け — 上記の
ロスレス性要件に反する。View 側(todos-entry.ts:2328 applyStructuredContent)は
structuredContent を丸ごと欲しがる。

---

## 4. HTML の読み込みとサンドボックス

### 発見とプリフェッチ(basic-host implementation.ts:91-156 の写経)

- ツール一覧から `_meta.ui.resourceUri`(新形式)→ `_meta["ui/resourceUri"]`
  (後方互換)の順で解決(app-bridge.ts:126-133 `getToolUiResourceUri`。
  caldav は両キー併記: server.ts:945-953 ほか)。
- `tools/call` 発行と**同時に** `resources/read` を並走(結果を待たず HTML を先に出す)。
- 検証: `mimeType === "text/html;profile=mcp-app"`(MUST, apps.mdx:268)。
  `csp`/`permissions` メタは content-level `_meta.ui` 優先・listing-level フォールバック
  (implementation.ts:137-153)。
- **キャッシュ**: `[uri: (html, uiMeta)]` を MCPConnection 単位で保持(同一 URI を
  list-todos / complete-todo 等 9 ツールが共有する — server.ts:1088 ほか)。
  無効化はセッション(接続)破棄時のみ。ETag 等はスパイク外。

### ロード方法

- **`webView.loadHTMLString(html, baseURL: nil)`**。baseURL nil → opaque origin 相当で、
  `file://` や本番オリジンの権限を持たない。postMessage は targetOrigin `"*"`
  (message-transport.ts:132)なので origin が opaque でも通る。
  caldav バンドルは自己完結(実行時 import ゼロ — todos-entry.ts 冒頭コメント)なので
  相対 URL 解決は不要。
- **非永続ストア**: `configuration.websiteDataStore = .nonPersistent()`。
  カード間・セッション間で Cookie/Storage を残さない(会話単位の分離に相当)。
- **ネットワーク遮断(スパイクでやる)**: `WKContentRuleList` で
  `{"trigger":{"url-filter":".*"},"action":{"type":"block"}}` の全遮断1ルールを
  コンパイルして適用。caldav バンドルはネットワークを使わないので全遮断で動くはず。
  加えて `WKNavigationDelegate` で初回ロード以外の navigation を `.cancel`、
  `WKUIDelegate.createWebViewWith` は nil(window.open 封じ。リンクは `ui/open-link` 経由)。
- **CSP `<meta>` 注入(スパイクでは省略・P3)**: 仕様のホスト義務は「宣言ドメインに
  基づく CSP 強制・未宣言は許可しない」(apps.mdx:274-287, 既定は
  `default-src 'none'` 系)。スパイクでは ContentRuleList 全遮断が実効的に同等以上に
  厳しいので、`_meta.ui.csp.connectDomains` → ルールリスト動的生成 + CSP meta 注入は
  P3 の堅牢化に回す。**設計上の置き場所**: HTML 文字列の `<head>` 直後に meta を挿す
  純関数を Kernel(`AppsProtocol/CSPInjector.swift`)に置き、swift-testing で
  単体テスト可能にする。
- **permissions(カメラ等, spec.types.ts:666-684)/ displayMode fullscreen**:
  スパイク外。initialize result では `availableDisplayModes: ["inline"]` を返し、
  `ui/request-display-mode` が来たら現状 mode を echo する(仕様上合法な最小応答)。

ボツ案: ローカル HTTP サーバや `WKURLSchemeHandler` で `ui://` を配信 — origin を
作れる利点はあるが、postMessage 方式に origin は不要で、可動部品が増えるだけ。却下。
ボツ案: baseURL に caldav 本番 URL — View に本番オリジンの信用を与えてしまう。却下。

---

## 5. サイズ交渉と SwiftUI レイアウト

仕様: host は `containerDimensions` を hostContext で渡し、**flexible 次元については
View の `ui/notifications/size-changed` を listen して反映しなければならない(MUST,
apps.mdx:718)**。View 側は autoResize(ResizeObserver)が既定で有効(app.ts:1837-1850)。

### 決定: 幅=ホスト固定・高さ=View 主導(basic-host:315-323 / 360-393 と同じ役割分担)

- チャット内インラインカード前提。初期 hostContext:
  `containerDimensions: { width: <カード実測幅 pt>, maxHeight: 600 }`
  (モバイル UX 資料の 300–360px viewport / コンパクトカード指針に整合)。
- Features 側 `AppCardView`:
  - `onGeometryChange` で幅変化を検知 → `session.setHostContext(containerDimensions:
    .init(width: newWidth, maxHeight: 600))`(basic-host が ResizeObserver でやっている
    ことの SwiftUI 版。implementation.ts:315-322)。
  - `size-changed` の height を actor から `@Observable` な
    `AppCardState.desiredHeight` に流し、`.frame(height:)` +
    `withAnimation(.easeOut(duration: 0.3))`(basic-host:392 の 300ms ease-out に合わせる)。
    上限 `min(desiredHeight, 600)` でチャットを食い潰さない。
  - width は size-changed が来ても無視(ホスト固定次元。仕様上 View は
    fixed 次元に従う義務がある — apps.mdx:691-711 の View 側 CSS 指針)。
- スクロール競合: WKWebView の `scrollView.isScrollEnabled = false`
  (高さは常に内容ぴったりに追従するので内部スクロール不要。todos カードの
  想定表示は一覧だが、View 側が max-height 内でスクロールを組むのは View の自由)。

ボツ案: `evaluateJavaScript("document.body.scrollHeight")` ポーリング —
プロトコルに size-changed がある以上、仕様外の裏道は取らない。

---

## 6. P2 スパイクの実装ステップと成功判定ゲート

前提: P1(OAuth + tools/call が swift-sdk で通る)完了済みの接続を使う。

1. **S1: Kernel/AppsProtocol** — JSONValue・JSON-RPC 封筒・§3 最小集合の Codable +
   swift-testing(spec.types.ts の JSON 例をフィクスチャに round-trip)。
2. **S2: WebViewTransport 単体疎通** — インターセプタ JS + WKScriptMessageHandler +
   `callAsyncJavaScript` 配送。検証は caldav に依らないミニ HTML
   (`window.parent.postMessage({jsonrpc:"2.0",...})` を送り、受けた echo を表示する
   10 行ページ)で、**§1 の3仮説(parent===window / isTrusted 判別 /
   stopImmediatePropagation の登録順)をシミュレータで先に潰す**。ここが最大リスクなので
   最初の可動物にする。
3. **S3: AppsBridgeSession** — 状態機械 + initialize 応答 + outbox。S2 のミニページを
   ext-apps の素の `App`(basic-server-vanillajs をローカルバンドル)に差し替えて
   initialize → initialized → tool-input 到達まで。
4. **S4: caldav 実カード** — `list-todos` を tools/call → `_meta.ui.resourceUri` 解決 →
   resources/read → loadHTMLString → tool-result 配送 → todos カード描画。
5. **S5: 往復** — カード内の complete 操作 → View の `app.callServerTool`
   (todos-entry.ts:1861/1888 と同経路)→ ブリッジ素通し → swift-sdk callTool →
   結果を JSON-RPC response で返す → View が自前で再描画。
6. **S6: 片付け** — teardown・ContentRuleList 全遮断・非永続ストア・
   size-changed → frame(height:)。

**判断ゲート(全部 YES で路線B続行 / NO が残れば §7 の代替 → それも駄目なら路線Aへ撤退)**:

- [ ] View 改変ゼロで `ui/initialize` リクエストが Swift 側に到達する(S2/S3)
- [ ] initialized 前に host が何も送っていないことをログで確認できる(仕様 MUST NOT)
- [ ] list-todos カードが実データで描画される(S4)
- [ ] カード内 complete → tools/call → tool-result/応答 → 打ち消し線描画の往復が
      1 サイクル通る(S5。becoming-done 演出まで出れば満点、一覧更新で合格)
- [ ] focus refetch(refresh-todos, `visibility:["app"]`)がモデルのツール一覧に
      **出ていない**こと(apps.mdx:400 の MUST。LLM オーケストレータ側の除外確認)
- [ ] ContentRuleList 全遮断下でカードが動く(自己完結バンドルの実証)
- [ ] size-changed で高さが追従し、チャットスクロールと喧嘩しない

---

## 7. リスクと代替案

| リスク | 兆候 | 代替(可逆な順) |
|---|---|---|
| `stopImmediatePropagation` が View のリスナーに効かない(登録順が崩れる等) | View が自分の送信を自分で受けて JSON-RPC id 衝突・多重応答 | 代替A: documentStart で `window.postMessage` 自体をラップし、View 由来呼び出しを webkit ハンドラへ直送(イベントを発生させない)。parent===window なので `window.parent.postMessage` も同じ関数。[Replaceable]/writable なので上書き可 |
| 合成 MessageEvent の `source: window` 指定が WebKit で落ちる | Host→View 配送で TypeError / View 側フィルタで無視される | 代替B: 代替A とセットで View の受信も乗っ取る — `addEventListener("message")` をラップして transport のリスナーを捕捉し、ホスト配送時に直接呼ぶ(イベント機構を使わない)。最終手段で確実 |
| WKContentWorld 分離時に世界間で event 伝播/stopImmediatePropagation の意味論が変わる | P3 堅牢化で S2 の再現テストが割れる | スパイクは .page world 固定(§1 で決定済み)。P3 で駄目なら page world + `Object.freeze` 系の自衛に留める |
| iOS 26 SwiftUI ネイティブ WebView(WebPage API) | — | **採用しない(WKWebView + UIViewRepresentable で行く)**。根拠: 最小 OS バージョンが授業要件で未決(CLAUDE.md)であり iOS 26 固定は不可逆に高い賭け。WKUserScript/ContentRuleList 相当の制御が新 API で揃うかも未検証。WebView 部分は Features の 1 View に閉じるので、将来の載せ替えは可逆 |
| caldav 側契約変更(_meta キー・mimeType) | 発見・検証で弾かれる | 契約の正は caldav 側(CLAUDE.md)。ズレたら caldav docs を先に直す規律で吸収 |
| すべて失敗 | ゲート NO | 路線A(TodosViewModel 契約のネイティブ SwiftUI 描画)へ撤退 — next-directions.md「路線の定義」に撤退先として明記済み |

## 8. 決定サマリ

1. postMessage ブリッジ = **documentStart インターセプタ + isTrusted 方向判別 +
   合成 MessageEvent(source: window)配送**。View 改変ゼロ・parent shim 不要。
2. 状態機械 = **actor AppsBridgeSession + State enum + outbox**(initialized 前送信禁止を機械化)。
3. Kernel 型 = **ui/* 最小集合を型写経、tools/call 系は JSONValue ロスレス素通し**。
4. HTML = **loadHTMLString(baseURL: nil) + 非永続ストア + ContentRuleList 全遮断**。
   CSP meta 注入・permissions・fullscreen は P3(注入純関数の置き場だけ Kernel に確保)。
5. サイズ = **幅ホスト固定 / 高さ size-changed 追従(上限 600・300ms ease-out)**。
6. スパイクは S2(transport 疎通)を最初の可動物にし、§6 のゲートで路線B続行を判定。

# 02 — チャット + ベンダー中立 LLM tool-use ループ + 履歴永続化(P3 設計)

> 2026-07-16 起票。P3 の設計図。docs/design/01-apps-bridge.md(P2)と同じ書式
> (決定・根拠・ボツ案・一次資料への出典行)。実装前の設計であり、実装で判明した事実は
> 「> 日付 更新:」で積層する(caldav docs/modeling の流儀)。
>
> 一次資料(ローカルで確認済み・行番号は 2026-07-16 時点。fable レビューで全行再裏取り済み):
> - MCP Apps visibility の MUST: `~/ghq/github.com/modelcontextprotocol/ext-apps/specification/2026-01-26/apps.mdx:395-401`
>   (397 = 省略時既定 `["model","app"]`、400 = tools/list の除外 MUST、**401 = app からの tools/call 拒否 MUST**)
> - swift-sdk `Tool`(`_meta: Metadata?`): `~/ghq/github.com/modelcontextprotocol/swift-sdk/Sources/MCP/Server/Tools.swift:11-27`。
>   `Metadata` の実体は `fields: [String: Value]` + subscript: `Sources/MCP/Base/Utilities/Progress.swift:94-103`
> - swift-sdk `Client` 実 API: `Sources/MCP/Client/Client.swift` —
>   `listTools(cursor:) -> (tools:[Tool], nextCursor:String?)`(:743)、
>   `callTool` タプル版(:768・structuredContent/_meta を捨てる)と
>   `RequestContext<CallTool.Result>` 版(:790)、`readResource(uri:) -> [Resource.Content]`(:700)
> - OpenAI chat/completions ストリーミング(Web・2026-07-16 参照):
>   https://developers.openai.com/docs/guides/function-calling(tool_calls delta の index 蓄積)/
>   https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events
>   (chunk 構造・finish_reason・`stream_options:{include_usage:true}` の最終 usage チャンク)
> - caldav の visibility 付与: `~/ghq/github.com/gigun-dev/caldav/src/presentation/mcp/server.ts:1525-1564`(todos)/`:981-995`(events)
> - 既存: `Sources/Services/MCP/MCPConnection.swift`、`Sources/Services/AppsBridge/*`、
>   `Sources/Services/Keychain/KeychainTokenStorage.swift`、`Sources/Features/Spike/TodosCardSpikeView.swift`
> - UI モック(合意済み): `docs/modeling/ui-mockups/chat-v1.html`

## 0. 全体像(何を作るか)

自然言語チャットで LLM が MCP ツールを叩き、ツール結果の `ui://` カードをチャット内に
そのままインライン描画するホスト。LLM 層は**ベンダー中立**(OpenAI 互換第一)、
**コスト効率が第一級の価値**(既定は軽量モデル・トークン費を意識・使用量を可視化)。

```
Features/Chat(SwiftUI)
  ├─ ChatView(メッセージ列 + ツールステップ + インラインカード + 入力欄 + コスト)
  ├─ ChatHistorySidebar(引き出し式・検索・日付グループ)
  └─ SettingsSheet(BYOK: base URL/キー/モデル・プリセット chips)
        │ 観測(@Observable)
        ▼
Services/Chat/ChatViewModel(tool-use ループのオーケストレータ)
  ├─ LLMClient(中立プロトコル)──▶ OpenAICompatClient(第一アダプタ・SSE)
  ├─ MCPConnection(P1)+ AppsServerProxy(P2)── caldav /mcp(tools/call)
  ├─ AppsBridgeSession + AppCardView(P2)── ツール結果カードの描画
  └─ ChatStore(履歴永続化・JSON ファイル)
        │
Kernel/LLMProtocol(OpenAI 互換ワイヤ型の Codable・純粋)
Kernel/ChatModel(Message/ToolCallStep/CardEmbed のドメイン型・純粋)
```

レイヤー配置(CLAUDE.md の3層方針。Kernel は依存ゼロ・純粋):

```
Sources/Kernel/LLMProtocol/    # OpenAI 互換の chat/completions リクエスト/レスポンス Codable(純粋)
Sources/Kernel/ChatModel/      # Message・ToolCallStep・CardEmbed・ChatSession のドメイン型 + 永続化 DTO(純粋)
Sources/Services/LLM/          # LLMClient プロトコル + OpenAICompatClient(URLSession/SSE)+ ツール変換
Sources/Services/Chat/         # ChatViewModel(tool-use ループ)+ ChatStore(永続化)+ CostEstimator
Sources/Features/Chat/         # ChatView・ChatHistorySidebar・SettingsSheet・InlineCard 配置
```

LLM 層・チャット層は caldav 非依存(MCP のツール名や structuredContent の形を知らない)。

---

## 1. 層分け: ワイヤ型・ドメイン型・変換の置き場

### 決定: OpenAI 互換ワイヤ型は Kernel/LLMProtocol、MCP↔LLM 変換は Services/LLM

- **Kernel/LLMProtocol**(純粋 Codable): `ChatCompletionRequest`(model・messages・tools・
  stream・temperature)、`ChatMessage`(role・content・tool_calls・tool_call_id)、
  `ToolDefinition`(type:"function"・function{name・description・parameters:JSON Schema})、
  `ChatCompletionChunk`(SSE の delta)、`Usage`(prompt_tokens・completion_tokens)。
  JSON Schema の値は P2 で作った `Kernel/AppsProtocol/JSONValue` を再利用(既に純粋・ロスレス)。
- **MCP tools/list → OpenAI tools 変換**は `Services/LLM`。swift-sdk の `Tool`
  (Tools.swift:11)の `name`/`description`/`inputSchema:Value` を ToolDefinition に写す。
  `inputSchema`(MCP.Value)→ JSONValue → JSON Schema はほぼ同型(JSON Schema Draft の
  object/properties/required)なので素直に移せる。**変換が Services なのは MCP.Value(swift-sdk 型)に
  触れるのが Services までだから**(Kernel は swift-sdk 非依存の制約・P2 で JSONValue を自前実装した
  のと同じ理由。docs/design/01-apps-bridge.md §3)。
- **チャットのドメイン型**は Kernel/ChatModel(下記 §5)。

ボツ案: ワイヤ型を Services に置く — Codable 変換は純粋関数でテストしたいので Kernel が正しい
(P2 の AppsProtocol と対称)。ボツ案: 独自の中立メッセージ型を作って OpenAI 互換型と二重管理 —
第一アダプタが OpenAI 互換である以上、中立型 ≒ OpenAI 型でよい。将来 Anthropic アダプタを足すとき、
Anthropic 固有型 ↔ 中立型の変換をそのアダプタ内に閉じる(§2 の拡張点)。過度な抽象化を今はしない。

---

## 2. LLMClient プロトコルと OpenAI 互換アダプタ

### 決定: ストリーミング前提のプロトコル、第一実装は OpenAI 互換 SSE

```swift
// Sources/Services/LLM/LLMClient.swift(輪郭)
protocol LLMClient: Sendable {
  // 1ターン分の補完を要求し、delta を AsyncStream で返す。tool_calls は
  // アダプタ内で蓄積し、ストリーム終端で完成した ToolCall 配列 + usage を渡す。
  func stream(_ request: ChatCompletionRequest) -> AsyncThrowingStream<LLMEvent, Error>
}
enum LLMEvent {
  case textDelta(String)                              // 本文の増分(吹き出しに逐次追記)
  case completed(FinishReason, [ToolCall], Usage?)    // ストリーム終端でまとめて1回
}
enum FinishReason { case stop, toolCalls, length, contentFilter, other(String) }
```

- **ストリーミングにする理由**: モックはターン単位表示だが、軽量モデルでも本文が長いと
  「無反応」に見える。SSE で textDelta を逐次描画すれば体感が上がる。OpenAI 互換は
  `stream:true` で `data: {...}\n\n` の SSE を返すので URLSession の `bytes(for:)` で受ける。
- **終端イベントを1つにする理由(レビューで訂正)**: OpenAI の SSE では
  `stream_options:{include_usage:true}` 時、**usage は finish_reason チャンクの後に
  `choices: []` の追加チャンクとして届き、その後に `data: [DONE]`**(API リファレンス
  streaming-events / create の `stream_options.include_usage` 記述)。つまり
  「finish_reason 到達 = イベント発火」にすると usage を取り逃す。アダプタは
  finish_reason・蓄積済み tool_calls・usage を内部に持ち、`[DONE]` で `completed` を
  1回だけ yield する。**パーサは `choices[0]` の存在を仮定してはならない**
  (usage チャンクは choices が空配列)。ストリーム中断時は usage チャンク自体が
  届かないことがある(公式記述)ので Usage? は optional。
- **OpenAICompatClient**: `URLSession.bytes(for:)` で SSE を行読みし、`data: [DONE]` で終端。
  各チャンクの `choices[].delta` を解釈。tool_calls delta の蓄積規則(公式
  function-calling ガイドのリファレンス実装と同じ): 各要素は `index` を持ち、
  **最初の delta に `id` と `function.name` が丸ごと載り、以降の delta は
  `function.arguments` の断片だけ**が届く。index キーの辞書に入れ、arguments を
  文字列連結して JSON を完成させる。蓄積ロジックは純関数(`ToolCallAccumulator`)に
  切り出して Kernel/LLMProtocol に置き、swift-testing で分割パターンをテストする。
- **base URL/キー/モデルはアダプタ生成時に注入**(BYOK 設定から)。認証は
  `Authorization: Bearer <key>`(OpenAI 互換の標準)。
- **拡張点(Anthropic ネイティブ第二アダプタ)**: `LLMClient` を実装する `AnthropicClient` を
  将来足すだけ。Anthropic Messages API 固有の型変換はそのファイルに閉じる。今回は**実装しない**が、
  プロトコルの粒度(stream + LLMEvent)が Anthropic の SSE(content_block_delta・tool_use)にも
  載ることを確認しておく(載る)。

ボツ案: 非ストリーミングで先に通す — 実装は楽だが tool-use ループと相性が悪い(ツール実行の
合間に「考え中」を見せられない)。SSE は URLSession 標準機能で足せるので最初から入れる。
ボツ案: Vercel AI SDK / LangChain 相当を持ち込む — JS 前提・重い(next-directions で不採用確定)。

---

## 3. tool-use ループ

### 決定: ChatViewModel が反復。visibility 除外・最大反復・複数 tool_call 対応

ループ(基本形):
1. ユーザー発話を messages に積む。
2. `tools` = MCP tools/list を **visibility フィルタ(§7)**してから OpenAI ToolDefinition に変換。
3. `LLMClient.stream(request)` を回す。textDelta は吹き出しに逐次反映。
4. `completed(.toolCalls, calls, usage)` なら、各 ToolCall を
   **`AppsServerProxy.callTool(name:arguments:) -> JSONValue`(AppsServerProxy.swift:123)で実行**。
   P2 で「タプル版 callTool は structuredContent/_meta を捨てる」問題を潰し、
   `RequestContext<CallTool.Result>` 経由のロスレス JSONValue を返す実装が既にある
   (01-apps-bridge.md §3 直後の 2026-07-15 更新)ので、**新 API は不要**。この1つの
   JSONValue を (a) `role:"tool"` メッセージ(シリアライズ or 要約)として messages に積み戻し、
   (b) UI 資源を持つツールなら AppsBridgeSession の tool-result にも配って**カードを描画**(§4)。
5. `completed(.stop, _, usage)` でなければ 2 に戻る(モデルがツール結果を見て次を判断)。
   usage は分岐によらず毎ターン計上(§6)。
6. **最大反復回数**(既定 8)で打ち切り、超過はエラー吹き出し(暴走・コスト暴発の防止)。

- **tools/list の取得経路**: 初回接続時の一覧は `MCPConnectionResult.tools`(P1)が既に持つ。
  再取得は `client.listTools(cursor:)`(Client.swift:743)。cursor ページングがあるので
  nextCursor が nil になるまで回す(caldav ≈18 ツールは1ページだが、ループは3行で済む)。
- **複数 tool_call**: OpenAI は1ターンで複数 tool_calls を返せる。並行実行(TaskGroup)して
  全結果が揃ってから次の LLM 呼び出しへ(messages には tool_call_id 順で積む)。ただしカード描画を
  伴うツールが複数同時に来るケースは稀(通常1つ)。
- **ツールステップの可視化**(モック): `completed(.toolCalls, ...)` 受信時に
  ToolCallStep(name・状態)をチャット列に挿し、完了で状態更新。
  「何のツールを呼んでいるか隠さない」。

ボツ案: ループを Kernel に置く — LLMClient/AppsServerProxy(Services 型)に依存するので Services が正。
ボツ案: 最大反復を設けない — 軽量モデルはツール選択を誤って往復ループしうる。コスト第一級の方針上、
ガードは必須。

---

## 4. MCP App カードのチャット組み込み

### 決定: 1ツール結果カード = 1 AppsBridgeSession(P2 の粒度を踏襲)・接続は共有

- P2 の AppsBridgeSession は「1セッション=1WKWebView=1ツールカード」(01-apps-bridge.md §2)。
  チャット内で複数カードが並ぶときも**各カードは独立セッション**。ただし **MCPConnection
  (swift-sdk Client)は接続1本を共有**(tools/call はどのカードからも同じ Client に流れる。
  AppsServerProxy は Client を注入されるだけなので共有は自然)。
- **tool_call 結果の二重配布**(§3-4): ツール結果は (a) LLM に返す `role:"tool"` テキスト
  (structuredContent を要約 or JSON 文字列)と (b) カードに渡す tool-result(生の CallToolResult)の
  両方へ配る。(b) は UI 資源(`_meta.ui.resourceUri`)を持つツールのみ(AppsServerProxy が判定済み)。
- **size-changed 追従の本実装**(P2 で §5 として先送りにした分): チャット内カードは幅=カード列の
  実測幅(親 View)、高さ=size-changed 追従(上限あり・チャットを食い潰さない)。P2 のスパイクでは
  単カード全画面で固定枠にしたが、チャットでは複数カードが縦に積まれるのでインラインカードの
  高さ追従がここで必要になる(AppCardWebViewFactory の scrollEnabled=false 経路を使う)。
- **カードの生存**: チャットスクロールで画面外に出ても WKWebView は保持(再生成は高コスト・
  状態が飛ぶ)。ただし §5 の履歴再訪では別扱い(スナップショット)。
  **メモリ上限(レビューで追記)**: ライブ WKWebView は現在セッション内でも上限
  (目安 5 枚)を設け、超過した最古のカードは §5 と同じスナップショット静的表示に降格する
  (スナップショット機構を T6 で作る以上、転用はほぼタダ。上限値の調整は可逆)。

ボツ案: 全カードで WKWebView を1枚共有 — セッション状態機械が1対1前提(01 §2)なので破綻。

---

## 5. チャット履歴の永続化

### 決定: JSON ファイル(1チャット=1ファイル)+ 一覧インデックス。カードはスナップショット HTML 保存

- **保存形式**: SQLite でなく **JSON ファイル**(1 ChatSession = 1 ファイル、
  `Application Support/chats/<uuid>.json`)+ 軽量な一覧インデックス(`index.json`: id・title・
  最終メッセージプレビュー・更新時刻・接続先)。理由: P3 の規模(個人利用・全文検索は不要)では
  SQLite は過剰。サイドバーは index.json を読むだけで日付グループ表示できる。
- **ChatModel(Kernel・純粋 Codable)**:
  - `ChatSession`(id・title・serverURL・createdAt・updatedAt・[ChatTurn])
  - `ChatTurn`(role・text・[ToolCallStep]・[CardEmbed]・usage)
  - `CardEmbed`(toolName・resourceUri・**snapshotHTML**・structuredContent:JSONValue・arguments・
    optional serverID/serverURL/originalToolName provenance)
- **カードの履歴再訪問題(重要な判断)**: WKWebView 由来のライブカードはそのまま保存できない。
  → **会話本文は保存時の記録として固定し、カードだけを live island として再接続**する。
  現在 ready な生成元を確実に同定できる場合、現在 tools/list が広告する UI resource HTML を読み、
  保存済み arguments / structuredContent を bootstrap として配送する。元 tool を Swift host が推測・
  自動再実行してはいけない。表示後の authoritative data は MCP server 側にあり、fresh data の取得は
  MCP App 自身が app-only refresh tool 等を tools/call する責務とする。生成元を同定できない場合だけ、
  最後の snapshot HTML を**静的表示(操作不可・ContentRuleList 全遮断・ブリッジ無し)**してfail closedにする。
  例えばcaldavでは `list-todos` / `complete-todo` / `delete-todo` 由来の同じtodos Appが
  `refresh-todos`、event系Appが`refresh-events`を副作用なしで呼び現在状態へ更新する。mutation由来でも
  元mutationを再実行しない。汎用hostはこのtool名やread/write性を知らず、refresh名を推測しない。
  新履歴は serverID + serverURL + originalToolName と現在のtool/UI広告を照合し、旧履歴は現在のwireNameが
  一意に厳密一致する場合だけbest-effortでlive化する。slug推測や別endpointへのfallbackは行わない。
  スナップショットは `webView.evaluateJavaScript("document.documentElement.outerHTML")` で取得。
  **技術的な限界と対処(レビューで追記)**: outerHTML は DOM のシリアライズであり
  (1) `<input>` の入力途中値・canvas 描画は落ちる(todos カードはリスト表示なので実害なし)、
  (2) インライン onclick / `<script>` はそのまま残る → 再訪ビューは
  `WKWebpagePreferences.allowsContentJavaScript = false` で **JS 実行自体を切って**ロードする
  (ブリッジ無し+ContentRuleList 全遮断に加えて。死んだボタンが JS エラーを吐くのも防げる)。
  取得タイミングは tool-result 配送後の size-changed 到達時(描画が確定した合図)を第一候補に、
  保険としてターン確定時にも取り直す。
- **保存タイミング**: 各ターン確定時(assistant の finished 到達時)にセッションを追記保存。
  index.json も同時更新。
- **検索**: 一覧の title/preview の部分一致で足りる(モックの検索フィールド)。全文検索(ターン本文)は
  据え置き(必要になったら index に本文の連結を足す)。

ボツ案: SQLite/CoreData/SwiftData — 個人規模には過剰。JSON ファイルは可搬でデバッグも楽。
将来スケール時に移行は可逆(Kernel の Codable 型はそのまま)。
ボツ案: WKWebViewをライブのまま全履歴で保持 — 大量保持はメモリ的に不可能。再訪時だけlive再構築し、
解決不能時のfallbackにsnapshotを使う。

---

## 6. コスト計測と表示

### 決定: usage×単価テーブルの概算。テーブルは持つが「不明なら非表示」で pretend しない

- OpenAI 互換レスポンスの `usage`(prompt_tokens・completion_tokens)を各ターンに記録。
  SSE では **`stream_options:{include_usage:true}` を必ず付ける**(付けないと届かない)。
  usage は `[DONE]` 直前の `choices: []` 追加チャンクで届く(§2 で裏取り済み・
  中断時は届かないことがあるので欠損許容)。互換プロバイダが stream_options 未対応の
  場合に備え、未知パラメータでの 400 は stream_options 無しで1回だけリトライする。
- **単価テーブル**(`Services/Chat/CostEstimator`): `[modelId: (inputPer1M, outputPer1M)]` の
  小さな辞書。既知モデルは概算 $ を出す。**未知モデルはトークン数だけ表示しコストは "—"**
  (誤った金額を見せない。BYOK で任意モデルを使える以上、全モデルの単価は持てない)。
- 表示(モック): 入力欄上「このターン ≈ N tok · $X」+ セッション累計(将来)。
- ※ 単価はハードコードすると陳腐化する。**モデル ID・単価は実装時に claude-api スキル等で
  裏取り**し、テーブルにコメントで出典と日付を残す(next-directions の方針)。

ボツ案: 全モデルの単価を追う — 保守不能。既知のみ + 未知は "—" が誠実。

---

## 7. visibility:["app"] 除外(MCP Apps の MUST)

### 決定: tools/list → LLM ツール変換の直前で除外。実装点は Services/LLM の変換関数

- **一次資料**: apps.mdx:400「Host MUST NOT include tools in the agent's tool list when their
  visibility does not include "model"(e.g. visibility:["app"])」。tools/call は app からは
  依然可能(apps.mdx:401・1490)。
- **caldav の該当ツール**: `refresh-todos` / `refresh-events`(server.ts:1564/995 で
  `_meta.ui.visibility:["app"]`)。focus refetch / mutation 後の再取得用で、**モデルには見せない**。
- **読み取り経路(具体化)**: swift-sdk `Tool._meta` の型は `MCP.Metadata`
  (Progress.swift:94。実体は `fields: [String: Value]` + `subscript(String) -> Value?`)。
  Services 側で `tool._meta?["ui"]`(`MCP.Value`)を JSONValue に変換(P2 の
  AppsServerProxy が使っている Value↔JSONValue 変換を再利用)してから、
  **Kernel の純関数 `isModelVisible(uiMeta: JSONValue?) -> Bool`** に渡す。
  こうすると Kernel は MCP.Value(swift-sdk 型)に触れない(依存ゼロ制約と整合)。
  判定: `uiMeta?.object?["visibility"]` が配列でなければ既定 `["model","app"]` 扱い
  (apps.mdx:397)= 残す。配列なら **"model" を含まないものだけ除外**。
- **実装点**: §1 の「MCP tools/list → OpenAI ToolDefinition 変換」関数の中で、変換前にフィルタ。
- **もう1つの MUST(ドラフトで抜けていた分・apps.mdx:401)**: 「Host MUST reject
  `tools/call` requests from apps for tools that don't include "app" in visibility」。
  P2 の AppsServerProxy.passthroughToolsCall は現状無条件素通しでこれを満たしていない。
  caldav の全ツールは省略既定 or ["app"] で "app" を含むため実害はないが、MUST なので
  **T2 で AppsServerProxy に「tools 一覧(visibility 判定関数込み)を注入し、
  "app" を含まないツールの app 発 tools/call を JSON-RPC error で拒否」を足す**
  (判定は同じ Kernel 純関数の対 `isAppCallable` を使う。変更は proxy 1 関数に閉じ可逆)。
- swift-testing: `_meta.ui.visibility:["app"]` のツールが LLM ツール一覧から落ち、
  省略/`["model","app"]` は残ること、`["model"]` のみのツールへの app 発呼び出しが
  拒否判定になることを純粋関数でテスト。

---

## 8. 履歴カードのrevalidation契約

保存済み`tool-result`はbootstrap表示であり、現在状態の証明ではない。履歴カードではresultの既存`_meta`を
保持したまま、`_meta["dev.gigun.mcphost/historical-revalidation"] = {required:true,
reason:"history", version:1}`を追加する。このnamespaced hintはMCP Apps標準の独自拡張で、未知fieldを無視する
generic Appの挙動を変えない。hostはtool input、structuredContent、元toolを変更・再実行せず、refresh tool名や
read/mutation分類も推測しない。

対応Appはhintを受けた初回`ontoolresult`をbootstrapとして描画後、自身が知る副作用なしrefresh toolを即座に
`callServerTool`する。この1回はfocus/pageshow用staleTimeの対象外にする。Swift hostは保存result配送前から
interaction overlayを置き、最初のApp-originated `tools/call`がサーバー往復・Viewへの応答配送まで完了し、かつ
CallToolResultの`isError`がtrueでない場合だけ操作を解放する。overlay中はユーザー操作を受けないため、この
最初のcallはApp自身のrevalidationでなければならない。

10秒以内に自動callが無い、transport失敗、`isError:true`、HTML/session構築失敗はいずれもfail closedとし、
保存表示を操作可能にはしない。再試行もhint付き保存resultの再配送だけで、hostから任意toolは呼ばない。
caldav側ではtodosが`refresh-todos`、agendaが`refresh-events`を選ぶ実装が必要である。

---

## 9. 実装ステップ分割(P2 の S1〜S6 に倣う)

P3 は技術リスクが P2 より低い(postMessage ブリッジ実証済み)。新規判断が要るのは
LLM ストリーミング・履歴永続化・複数カードのセッション管理。

1. **T1: Kernel/LLMProtocol + ChatModel** — OpenAI 互換ワイヤ型・チャットドメイン型の Codable +
   swift-testing(round-trip・visibility 解釈純関数・tool_calls delta 蓄積の純ロジック)。
2. **T2: Services/LLM** — LLMClient プロトコル + OpenAICompatClient(SSE)+ MCP→OpenAI ツール変換
   (visibility 除外込み)+ AppsServerProxy への app 発 tools/call 拒否(§7 の 401 MUST)。
   検証は OpenAI 互換のモック/実プロバイダ(OpenRouter の無料枠 or Ollama)に
   単発補完 → tool_calls が返り usage チャンク(choices 空)がパースを壊さないことを確認。
3. **T3: Services/Chat/ChatViewModel** — tool-use ループ(最大反復・複数 tool_call・ツールステップ)。
   MCPConnection(P1)+ AppsServerProxy(P2)配線。カード無しのテキスト往復をまず通す。
4. **T4: Features/Chat/ChatView + Settings** — チャット UI(モック chat-v1.html を SwiftUI 化)+
   BYOK 設定シート(Keychain)。MCPHOST_SPIKE でなく通常起動の主画面にする。
5. **T5: インラインカード** — ツール結果カードをチャットに埋め込み(AppsBridgeSession 再利用・
   size-changed 追従の本実装)。caldav の list-todos を「見せて」で描画 → カード内 complete が
   往復する E2E(P2 の往復をチャット文脈で再現)。
6. **T6: 履歴永続化 + サイドバー** — ChatStore(JSON)+ ChatHistorySidebar(引き出し・検索・
   日付グループ)+ カードのスナップショット保存/live再接続（解決不能時は静的再訪）。
7. **T7: コスト表示** — usage 計上 + CostEstimator + 画面表示。

**判断ゲート(P2 ほど硬くないが確認すべき点)**:
- [x] 軽量モデル(Flash-Lite/Haiku 級)が caldav ≈18 ツールから正しいツールを選べる(T3。
      選べないならツール説明の改善 or モデル格上げの判断材料)
- [x] visibility:["app"] が LLM ツール一覧から除外されている(T2・apps.mdx:400 MUST)
- [x] "app" を含まないツールへの app 発 tools/call が拒否される(T2・apps.mdx:401 MUST)
- [x] チャット内 complete がカード経由で往復する(T5)
- [x] 履歴再訪で同一serverのカードだけlive化し、解決不能カードを静的fallbackへ倒す(T6)
- [x] トークン/コストが表示され、未知モデルで嘘の金額を出さない(T7)

> **2026-07-23 更新:** T1〜T7の実装と実機E2Eは完了。履歴live化のうち、現在状態をApp自身に
> refreshさせてから操作を解放する追加gateはworking treeで実装・検証済み、caldav側hint対応は未完了。

## 10. 決定サマリ

1. ワイヤ型 = Kernel/LLMProtocol(OpenAI 互換 Codable)、MCP↔LLM 変換 = Services/LLM。
2. LLMClient = **ストリーミング(SSE)前提**プロトコル(`textDelta` + 終端 `completed` の
   2イベント。usage は `[DONE]` 直前の choices 空チャンクで届くため終端で1回)、
   第一実装 OpenAICompatClient。Anthropic ネイティブは拡張点のみ(実装しない)。
3. tool-use ループ = ChatViewModel。**visibility 除外・最大反復8・複数 tool_call 並行**。
4. カード = 1結果1セッション(P2 踏襲)・接続共有・結果は LLM とカードへ二重配布・
   size-changed 追従を本実装。
5. 履歴 = JSON ファイル + index。会話本文は固定、カードは現在の同一serverへlive再接続する。
   現在UI resource + 保存resultでbootstrapし、hostは元toolを自動再実行しない。解決不能時だけ
   snapshot HTMLをJS無効で静的表示する。ライブ WKWebView は上限付き(超過は降格)。
6. コスト = usage×単価テーブル概算・**未知モデルは "—"**(嘘の金額を出さない)。
7. visibility の MUST は2つとも守る: (a) "model" を含まないツールを LLM 一覧から除外
   (apps.mdx:400・変換直前)、(b) "app" を含まないツールへの app 発 tools/call を拒否
   (apps.mdx:401・AppsServerProxy)。判定は Kernel 純関数(`Tool._meta` は `MCP.Metadata`、
   JSONValue へ変換してから渡す)。

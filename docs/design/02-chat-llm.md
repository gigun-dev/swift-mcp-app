# 02 — チャット + ベンダー中立 LLM tool-use ループ + 履歴永続化(P3 設計)

> 2026-07-16 起票。P3 の設計図。docs/design/01-apps-bridge.md(P2)と同じ書式
> (決定・根拠・ボツ案・一次資料への出典行)。実装前の設計であり、実装で判明した事実は
> 「> 日付 更新:」で積層する(caldav docs/modeling の流儀)。
>
> 一次資料(ローカルで確認済み・行番号は 2026-07-16 時点):
> - MCP Apps visibility の MUST: `~/ghq/github.com/modelcontextprotocol/ext-apps/specification/2026-01-26/apps.mdx:395-401`
> - swift-sdk `Tool`(`_meta` あり): `~/ghq/github.com/modelcontextprotocol/swift-sdk/Sources/MCP/Server/Tools.swift:11-24`
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
  // アダプタ内で蓄積し、finish 時に完成した ToolCall 配列 + usage を渡す。
  func stream(_ request: ChatCompletionRequest) -> AsyncThrowingStream<LLMEvent, Error>
}
enum LLMEvent {
  case textDelta(String)            // 本文の増分(吹き出しに逐次追記)
  case toolCallsReady([ToolCall])   // finish_reason == "tool_calls"。ループが tools/call を実行
  case finished(Usage?)             // finish_reason == "stop"。usage でコスト計上
}
```

- **ストリーミングにする理由**: モックはターン単位表示だが、軽量モデルでも本文が長いと
  「無反応」に見える。SSE で textDelta を逐次描画すれば体感が上がる。OpenAI 互換は
  `stream:true` で `data: {...}\n\n` の SSE を返すので URLSession の `bytes(for:)` で受ける。
- **OpenAICompatClient**: `URLSession.bytes(for:)` で SSE を行読みし、`data: [DONE]` で終端。
  各チャンクの `choices[0].delta` を解釈。tool_calls は delta で分割して届く(index ごとに
  name/arguments を継ぎ足す)ので、アダプタ内で index キーの辞書に蓄積し finish_reason で確定。
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
4. `toolCallsReady` が来たら、各 ToolCall を **AppsServerProxy 経由で tools/call**(P2 で実装済み・
   caldav 非依存の素通しプロキシ)。結果を (a) `role:"tool"` メッセージとして messages に積み戻し、
   (b) UI 資源を持つツールなら AppsBridgeSession にも tool-result を配って**カードを描画**(§4)。
5. `finished` まで来なければ 2 に戻る(モデルがツール結果を見て次を判断)。
6. **最大反復回数**(既定 8)で打ち切り、超過はエラー吹き出し(暴走・コスト暴発の防止)。

- **複数 tool_call**: OpenAI は1ターンで複数 tool_calls を返せる。並行実行(TaskGroup)して
  全結果が揃ってから次の LLM 呼び出しへ(messages には tool_call_id 順で積む)。ただしカード描画を
  伴うツールが複数同時に来るケースは稀(通常1つ)。
- **ツールステップの可視化**(モック): `toolCallsReady` 受信時に ToolCallStep(name・状態)を
  チャット列に挿し、完了で状態更新。「何のツールを呼んでいるか隠さない」。

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
  - `CardEmbed`(toolName・resourceUri・**snapshotHTML**・structuredContent:JSONValue)
- **カードの履歴再訪問題(重要な判断)**: WKWebView 由来のライブカードはそのまま保存できない。
  → **最後のスナップショット HTML を保存**し、履歴再訪時はそれを**静的表示(操作不可・
  ContentRuleList 全遮断のまま・ブリッジ無し)**する。理由: (1) 再実行(tools/call やり直し)は
  副作用・コスト・サーバー状態変化を伴い履歴の意味が壊れる、(2) スナップショットなら安全に
  「そのときの見た目」を復元できる。ライブに戻したければ再訪画面から明示的に再実行させる(将来)。
  スナップショットは `webView.evaluateJavaScript("document.documentElement.outerHTML")` で取得。
- **保存タイミング**: 各ターン確定時(assistant の finished 到達時)にセッションを追記保存。
  index.json も同時更新。
- **検索**: 一覧の title/preview の部分一致で足りる(モックの検索フィールド)。全文検索(ターン本文)は
  据え置き(必要になったら index に本文の連結を足す)。

ボツ案: SQLite/CoreData/SwiftData — 個人規模には過剰。JSON ファイルは可搬でデバッグも楽。
将来スケール時に移行は可逆(Kernel の Codable 型はそのまま)。
ボツ案: カードをライブのまま履歴保持 — WKWebView の大量保持はメモリ的に不可能。スナップショットが正。

---

## 6. コスト計測と表示

### 決定: usage×単価テーブルの概算。テーブルは持つが「不明なら非表示」で pretend しない

- OpenAI 互換レスポンスの `usage`(prompt_tokens・completion_tokens。SSE では最終チャンク or
  `stream_options:{include_usage:true}` で届く)を各ターンに記録。
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
- **読み取り経路**: swift-sdk `Tool._meta`(Tools.swift:24)→ `ui.visibility` 配列。
  `visibility` 省略時の既定は `["model","app"]`(apps.mdx:397)なので、**"model" を含まないものだけ
  除外**(省略=含む=残す)。
- **実装点**: §1 の「MCP tools/list → OpenAI ToolDefinition 変換」関数の中で、変換前にフィルタ。
  P2 の AppsServerProxy は tools/call の素通しなので、そちらは触らない(app からの
  refresh-todos 呼び出しは通す必要がある = 除外は「LLM に見せる一覧」だけ)。
- swift-testing: `_meta.ui.visibility:["app"]` のツールが LLM ツール一覧から落ち、
  省略/`["model","app"]` は残ることを純粋関数でテスト(Kernel に visibility 解釈の純関数を置き、
  変換は Services から呼ぶ)。

---

## 8. 実装ステップ分割(P2 の S1〜S6 に倣う)

P3 は技術リスクが P2 より低い(postMessage ブリッジ実証済み)。新規判断が要るのは
LLM ストリーミング・履歴永続化・複数カードのセッション管理。

1. **T1: Kernel/LLMProtocol + ChatModel** — OpenAI 互換ワイヤ型・チャットドメイン型の Codable +
   swift-testing(round-trip・visibility 解釈純関数・tool_calls delta 蓄積の純ロジック)。
2. **T2: Services/LLM** — LLMClient プロトコル + OpenAICompatClient(SSE)+ MCP→OpenAI ツール変換
   (visibility 除外込み)。検証は OpenAI 互換のモック/実プロバイダ(OpenRouter の無料枠 or Ollama)に
   単発補完 → tool_calls が返ることを確認。
3. **T3: Services/Chat/ChatViewModel** — tool-use ループ(最大反復・複数 tool_call・ツールステップ)。
   MCPConnection(P1)+ AppsServerProxy(P2)配線。カード無しのテキスト往復をまず通す。
4. **T4: Features/Chat/ChatView + Settings** — チャット UI(モック chat-v1.html を SwiftUI 化)+
   BYOK 設定シート(Keychain)。MCPHOST_SPIKE でなく通常起動の主画面にする。
5. **T5: インラインカード** — ツール結果カードをチャットに埋め込み(AppsBridgeSession 再利用・
   size-changed 追従の本実装)。caldav の list-todos を「見せて」で描画 → カード内 complete が
   往復する E2E(P2 の往復をチャット文脈で再現)。
6. **T6: 履歴永続化 + サイドバー** — ChatStore(JSON)+ ChatHistorySidebar(引き出し・検索・
   日付グループ)+ カードのスナップショット保存/静的再訪。
7. **T7: コスト表示** — usage 計上 + CostEstimator + 画面表示。

**判断ゲート(P2 ほど硬くないが確認すべき点)**:
- [ ] 軽量モデル(Flash-Lite/Haiku 級)が caldav ≈18 ツールから正しいツールを選べる(T3。
      選べないならツール説明の改善 or モデル格上げの判断材料)
- [ ] visibility:["app"] が LLM ツール一覧から除外されている(T2・MUST)
- [ ] チャット内 complete がカード経由で往復する(T5)
- [ ] 履歴再訪でカードがスナップショット表示され、誤って副作用が起きない(T6)
- [ ] トークン/コストが表示され、未知モデルで嘘の金額を出さない(T7)

## 9. 決定サマリ

1. ワイヤ型 = Kernel/LLMProtocol(OpenAI 互換 Codable)、MCP↔LLM 変換 = Services/LLM。
2. LLMClient = **ストリーミング(SSE)前提**プロトコル、第一実装 OpenAICompatClient。
   Anthropic ネイティブは拡張点のみ(実装しない)。
3. tool-use ループ = ChatViewModel。**visibility 除外・最大反復8・複数 tool_call 並行**。
4. カード = 1結果1セッション(P2 踏襲)・接続共有・結果は LLM とカードへ二重配布・
   size-changed 追従を本実装。
5. 履歴 = JSON ファイル + index。**カードはスナップショット HTML で静的再訪**(再実行しない)。
6. コスト = usage×単価テーブル概算・**未知モデルは "—"**(嘘の金額を出さない)。
7. visibility:["app"] 除外は変換直前・`Tool._meta.ui.visibility` から判定(MUST・apps.mdx:400)。

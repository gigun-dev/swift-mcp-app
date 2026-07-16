# 設計 03: ツール I/O 契約とカード鮮度・観測基盤(P3 実運用で表面化した3論点)

> 2026-07-15 起票。P3(T1〜T5 実装済み・実機 end-to-end 成立)で表面化した3論点の恒久設計。
> docs/design/01-apps-bridge.md / 02-chat-llm.md と同じ書式(決定・根拠・ボツ案・一次資料への出典行)。
> 実装前の設計文書であり、実装で判明した事実は「> 日付 更新:」で積層する。
>
> 一次資料(すべてローカル or raw GitHub で確認済み。行番号は 2026-07-15 時点のチェックアウト):
> - MCP 仕様 schema: https://raw.githubusercontent.com/modelcontextprotocol/modelcontextprotocol/main/schema/2025-11-25/schema.ts
>   (`CallToolRequestParams` — `name: string` 必須、`arguments?: { [key: string]: unknown }` **optional**)
> - swift-sdk: ~/ghq/github.com/modelcontextprotocol/swift-sdk/Sources/MCP/Client/Client.swift:768-797(callTool)、
>   Sources/MCP/Server/Tools.swift:365-402(CallTool.Parameters の encodeIfPresent)
> - TS SDK(caldav が使う実物): ~/ghq/github.com/gigun-dev/caldav/node_modules/@modelcontextprotocol/sdk/dist/esm/server/mcp.js:125,166-179、
>   同 zod-compat.js:14-25,37-46
> - caldav サーバー: ~/ghq/github.com/gigun-dev/caldav/src/presentation/mcp/server.ts:652-658,1508-1522,1553-1570
> - ext-apps 規範仕様: ~/ghq/github.com/modelcontextprotocol/ext-apps/specification/2026-01-26/apps.mdx:485,507,1106-1169、395-402(visibility)
> - ext-apps SDK: ~/ghq/github.com/modelcontextprotocol/ext-apps/src/app.ts:281,373-395,858-873
> - caldav カード実体: ~/ghq/github.com/gigun-dev/caldav/src/presentation/mcp/ui/todos-entry.ts:2570-2645,2700,2786-2794,3301-3310,3354-3400、
>   todos-diff-client.ts:65,95-97,112-153
> - 本アプリ: Sources/Services/Chat/ChatViewModel.swift:122-353、Sources/Services/AppsBridge/AppsServerProxy.swift:145-223、
>   Sources/Services/Chat/MCPToolExecuting.swift:24-33、Sources/Services/AppsBridge/AppsBridgeSession.swift:114-119,347-366、
>   Sources/Features/Chat/InlineCardView.swift:114-115

## 0. 全体像(3論点の関係)

論点1(arguments 契約)は**バグ確定済みの即修正対象**で、論点2の誤演出(空→4件の「追加」緑演出)の直接の引き金。
論点2はそれを取り除いた後も残る「ホスト配送 vs カード自己 refresh」の恒久的な役割分担の問い。
論点3は T6(ChatStore)前に決めるべき観測の継ぎ目の設計。層はこう切る:

```
Sources/
├── Kernel/          # ChatTraceEvent(論点3のイベント型: 純データ・Codable)
├── Services/
│   ├── AppsBridge/  # AppsServerProxy — 論点1の不変条件「LLM 発呼び出しは arguments を必ず object で載せる」担保点
│   │                # AppsBridgeSession — 論点2の tool-input→tool-result 初回配送(現行維持)
│   └── Chat/        # ChatViewModel — 論点1の decodeArguments 修正、論点3の TraceSink 注入点
└── Features/        # InlineCardView — 論点2「isError 結果はカードを起こさない」
```

## 1. 論点1: ツール引数の受け渡し契約(バグ確定・最優先)

### 確認された機序(一次資料の連鎖)

1. **MCP 仕様では `arguments` は optional**。schema.ts(2025-11-25)`CallToolRequestParams`:
   `arguments?: { [key: string]: unknown }`。省略も `{}` もワイヤ上どちらも仕様適合。
2. **swift-sdk は nil ならキーごと省略**。Tools.swift:401 `try container.encodeIfPresent(arguments, forKey: .arguments)`
   — `arguments == nil` のとき `{}` すら送らずフィールド自体が消える。Client.swift:770/792 の
   `arguments: [String: Value]? = nil` がその入口。
3. **TS SDK(サーバー側)は省略を `{}` に正規化しない**。mcp.js:125
   `validateToolInput(tool, request.params.arguments, ...)` — 省略時は `undefined` がそのまま
   zod へ渡り(mcp.js:174 `safeParseAsync(schemaToParse, args)`)、`z.object(shape)` は
   `undefined` を拒否して mcp.js:178 `McpError(InvalidParams, "Input validation error: ...")`
   → `isError:true` の CallToolResult になる。全フィールド `.optional()`(caldav server.ts:652-658
   `listTodosInputShape`)でも救われない — optional なのはフィールドであってオブジェクト自体ではない。
4. **本アプリが `{}` を nil に畳んでいた**。ChatViewModel.swift:323-336 `decodeArguments`:
   空文字→nil(:325)、パース不能→nil(:326-331)、**`.object` で空→nil(:334)**。
   → AppsServerProxy.swift:216 `guard let arguments else { return nil }` → 2 によりワイヤ省略 → 3 で失敗。
5. 一方カード発 refresh-todos は passthroughToolsCall(AppsServerProxy.swift:172-193)経由で
   カードが積んだ `{}` がそのまま `callTool(arguments: params?["arguments"])` に届くので成功。
   list-todos と refresh-todos は**同一入力スキーマ**(caldav server.ts:1562 が :652 の
   `listTodosInputShape` を共用)— 違いは null か {} だけ、という実機ログと完全に一致。

つまり「仕様上 optional」×「TS SDK は実質 `{}` を要求」×「swift-sdk は nil を省略」×「本アプリが
`{}` を nil に畳む」の4段の噛み合わせ事故。TS SDK は MCP サーバー実装の圧倒的多数派なので、
**汎用ホストは「省略」を選ぶ理由が無く「常に `{}` 以上を送る」が唯一堅牢**。
(arguments 無しを許すサーバーにとって `{}` は無害 — 仕様上 `{ [key: string]: unknown }` の
空インスタンスとして常に妥当。)

### 決定: 不変条件「LLM 発のツール呼び出しは arguments を常に JSON object としてワイヤに載せる(省略しない)」— 担保点は AppsServerProxy.mcpArguments

修正は2箇所・役割を分けて置く:

**(a) AppsServerProxy.swift:215-216 `mcpArguments(from:)` — ワイヤ不変条件の担保(本丸)**

```swift
// 変更前: guard let arguments else { return nil }
// 変更後: nil は空オブジェクトに正規化して必ず arguments フィールドを載せる
guard let arguments else { return [:] }
```

- ここが `client.callTool` の直前・LLM 発(callTool)とカード発(passthroughToolsCall → callTool)の
  **合流点**なので、1箇所で両経路の不変条件になる。
- MCPToolExecuting(MCPToolExecuting.swift:27)のドキュメンテーションコメントに不変条件を明記:
  「`arguments: nil` は『引数なし』の意図として受けるが、ワイヤでは `{}` として送る。
  フィールド省略は行わない(TS SDK の zod object 検証が undefined を拒むため)」。
- object 以外の拒否(:217-218)は現状維持。

**(b) ChatViewModel.swift:334 `decodeArguments` — 空 `{}` の畳み込みを削除**

```swift
// 削除: if case .object(let dict) = value, dict.isEmpty { return nil }
// 変更: 空文字(:325)は .object([:]) を返す(「モデルが引数なしを表明した」の正規形)
```

- モデルが `"{}"` を吐いたという事実を nil に握りつぶさない。JSONValue 素通し方針(02)とも整合
  — (a) があれば nil でも結果は同じだが、「モデルの出力を情報落ちなく下流へ渡す」層責務として直す。

**(c) 壊れた JSON(:326-331)は `{}` で送らず、エラーを role:"tool" でモデルに返す**

- `{}` で送るとモデルが意図した引数(例: `{"calendarId": ...` の途中切れ)と**別の呼び出し**が
  成功してしまい、誤データで会話が進む。失敗をモデルに見せればモデルは自力でリトライできる
  (execute の失敗経路 ChatViewModel.swift:304-317 が既にループを止めずエラー文言を積む設計)。
- 実装: `decodeArguments` を `Result<JSONValue, ArgumentDecodeError>` 相当に変え、パース不能なら
  `execute` がツールを**呼ばずに** role:"tool" へ `"tool call arguments が JSON として不正: <raw先頭N文字>"`
  を返す。ワイヤに壊れたまま流さないのはホストの防波堤責務。

**検証(swift-testing・Kernel/Services 単体で回る)**:
- `decodeArguments("")` / `("{}")` が `.object([:])` を返す。
- `mcpArguments(from: nil)` が `[:]`(非 nil)を返す — swift-sdk encodeIfPresent でフィールドが出ることの担保。
- 壊れ JSON でツール未実行+エラー role:"tool" が積まれる。

**可逆性: 高。** すべてホスト内部の正規化で、サーバー・カード・LLM のどの契約も変えない。
仮に「arguments フィールドの有無で挙動を変えるサーバー」が将来現れても、mcpArguments の1行を
戻すだけ(その場合はツールごとのポリシー化を検討)。

**ボツ案:**
- **swift-sdk 側を直す(encodeIfPresent をやめる)**: SDK にとって「nil=省略」は仕様(optional)通りの
  正しい挙動。上流フォークは保守コストが不可逆に増える。却下。
- **caldav 側で undefined を許す(inputShape を z.object().optional() 化 or SDK 更新待ち)**: caldav を
  直しても本アプリは「汎用ホスト」なので他の TS SDK 製サーバーで同じ事故が再発する。ホスト側で
  常時 `{}` を送るのが中立性(ビジョン2)に適う。caldav 側は変更不要(docs/caldav-feedback.md 追記も不要
  — サーバーは TS SDK の標準挙動のまま)。却下。
- **ChatViewModel(execute)で nil→`{}` に変換**: LLM 経路しか救えず、将来 passthrough 以外の
  呼び出し元が増えたとき不変条件が漏れる。担保は合流点(Proxy)に置く。却下(ただし (b)(c) の
  「モデル出力の解釈」は ChatViewModel の責務なのでそこに残す — 解釈とワイヤ正規化の分離)。

## 2. 論点2: カードのデータ鮮度モデルと「追加」誤演出

### 一次資料で確定した契約

- **tool-result 配送はホストの MUST(ただし初回・表示中のみ)**。apps.mdx:1155
  "Host MUST send this notification when tool execution completes (if the View is displayed during
  tool execution)"。順序契約: tool-input が先(apps.mdx:1118 "required before sending
  `ui/notifications/tool-result`")。**再実行・後続ターンでの再送は仕様に無い**。
- **周期的な鮮度はカード側責務**。caldav カードは初期描画ではホストの push を待ち
  (todos-entry.ts:3390-3400、5秒タイムアウト)、以後 visibilitychange/focus/pageshow で
  `refresh-todos` を自分で叩く(todos-entry.ts:3383-3388 → 2700 `callServerTool({name:"refresh-todos"})`、
  stale 2500ms・mutation 中は抑制 :3366-3382)。カード自身のコメント(:3354-3360)が
  「ホストの再実行 push は仕様で保証されないので app 駆動で取り直す」と明記 — 本アプリの
  現行実装(初回1往復のみ配送、AppsBridgeSession.swift:114-119 + InlineCardView.swift:114-115)と
  役割分担が既に一致している。
- **「+ ボタンで同期が走る?」→ 走らない(確定)**。FAB click(todos-entry.ts:3301-3310)は
  `startDraft()`(:1190-1197、ローカルにドラフト行を生やすだけ)でサーバー呼び出しゼロ。
  refresh-todos が走るのは (A) focus 系 refetch、(B) mutation 応答が currentView と矛盾する
  非既定ビューの取り直し(:2794,2910,3074,3234)、(C) view reconcile(:2614-2620,2645)のみ。
- **「追加」誤演出の正体**: diff エンジンは初回描画では呼ばれない契約
  (todos-diff-client.ts:95-96「prev が空なら next 全行が『追加』に見えるため entry 側は初回描画では
  本関数を呼ばない」)。今回の事故は論点1の失敗で**「空の tool-result」が正常な初回描画として
  ingest され prev=[] が確立**→ 直後の focus refetch で 4件が「prev に無い id」(:126-128)として
  added 演出になった、という構造。カードの diff 実装は契約通りで caldav 側のバグではない。

### 決定: 役割分担は現行維持(ホスト=初回 tool-input→tool-result 配送のみ・鮮度はカード自己 refresh)。ホスト側は「isError 結果でカードを起こさない」を追加

1. **配送モデルは変えない**。spec の MUST(初回配送)と caldav カードの設計(app 駆動 refresh)が
   既に噛み合っており、ホストが後続ターンで再 push する拡張は契約外挙動としてカード側が防御対象に
   している(todos-entry.ts:2597-2620 が実測済みの契約外 push への防御)。二重更新のちらつきは
   「ホストが余計な配送をしない」ことで構造的に避ける。
2. **isError:true の CallToolResult ではインラインカードを生成しない**(置き場:
   ChatViewModel.swift:256-265 のカード記録経路 — CardEmbed を作る条件に `isError != true` を追加)。
   論点1修正で今回の事故は消えるが、恒久的にも「失敗結果を初回描画として ingest させ prev を
   確立させる」経路はホストが塞ぐのが正しい。エラーは role:"tool" でモデルに返り(:304-317)、
   モデルがリトライ → 成功結果で初めてカードが立つ。spec 1155 の MUST は「表示中の View」への
   配送義務であり、結果到着後にカードを生成する本アプリのインライン方式では「エラー時は View を
   表示しない」選択は仕様違反にならない。
3. **caldav-feedback.md への追記は「提案(低優先)」1件のみ**: 「ontoolresult で受けた
   structuredContent が空/欠損でも prev を確立する(todos-entry.ts:2581 → ingest)ため、ホストが
   誤って空結果を push すると直後の refetch が全件 added 演出になる。ingest 時に
   『tasks が取れない結果では prev を確立しない』防御があるとより堅牢」。ただし一次的な対処は
   ホスト側(上記2)であり、caldav 側は任意。誤演出そのもの(diff 演出のロジック)は契約通りで
   caldav の対処不要、と明記する。

**可逆性: 高。** 2 はカード生成条件の1条件で、外すのも足すのも局所変更。1 は「何もしない」決定
なので、将来 spec が再送契約を定義したら(draft 監視)追従すればよい。

**ボツ案:**
- **ホストが tool 結果を毎ターン再 push して鮮度を保つ**: 仕様に無い契約外挙動(カードが防御コードを
  持つ羽目になっている実例あり)。visibility ゲート(apps.mdx:400-401 — app-only ツールの
  tools/list 除外 MUST NOT / app 以外からの呼び出し拒否 MUST)を含め、鮮度は
  server↔app の閉ループに任せるのが ext-apps の設計思想。却下。
- **ホストが refresh をトリガする(カードに再取得を指示する独自メッセージ)**: 独自拡張は汎用ホストの
  中立性(ビジョン2)に反する。却下。
- **エラー時も「エラーカード」を表示**: エラー表現は View(カード HTML)の責務ではなくチャット UI の
  責務(既に toolSteps の failed 表示がある)。二重表現になるだけ。却下。

## 3. 論点3: 観測・トレース基盤の置き場と継ぎ目

### 決定: 観測は swift-mcp-app の責務。今は ChatStore + OSLog、外部トレース(Langfuse/OTel)は LLM プロキシ段階でサーバー側に置く。今やるのは「TraceSink 1 seam」の設計のみ

**責務の線引き**(明文化):

| 層 | 見えるもの | 置き場 |
|---|---|---|
| caldav(サーバー) | 自分への /mcp リクエストのみ | Workers observability(caldav 側の既存要件・変更なし) |
| swift-mcp-app(ホスト) | 会話全体: turn・tool_call 選択・args・result・usage | ChatStore(T6)+ OSLog + TraceSink |
| LLM プロキシ(将来・Workers) | 全ユーザーの LLM トラフィック | Langfuse / OTel(サーバー側計装) |

「ユーザーのチャットと tool calling の分析」は LLM オーケストレーションの観測であり、
ツールサーバー(caldav)には構造的に見えない(どのモデルが・なぜそのツールを・いくらで、は
ホストにしか無い)。**caldav の要件にはならない**。

**今クライアント側 Langfuse を入れない根拠**:
- BYOK 単一ユーザーの現在、分析対象は自分のデバイス内で完結する。ChatStore(T6 設計済み:
  02 §5、turns/toolSteps/args/results/usage の JSON 永続化)がそのまま一次データになる。
- クライアントから外部 SaaS へ会話データを送る経路を作ると、SaaS 化(ビジョン1)のとき
  「ユーザーデータがクライアントから第三者に出る」設計を背負い直すことになる。プロキシ段階なら
  サーバー側(Workers → Langfuse/OTel エクスポート)に置けて、クライアントは何も知らなくてよい。
  LLM エンドポイント抽象(CLAUDE.md ビジョン1「Services/LLM の1箇所」)とトレースの継ぎ目が
  同じ場所に落ちるのが利点。
- 可逆性の観点: 「後で足す」は seam があれば軽い。「今入れて後で剥がす」は SDK 依存・
  データ持ち出し済みの両面で重い。→ 遅延が正しい。

**TraceSink seam の輪郭**(T6 と同時に実装):

```swift
// Sources/Kernel/Tracing/ChatTraceEvent.swift — 純データ・Codable(Kernel: プラットフォーム非依存)
public enum ChatTraceEvent: Sendable, Codable {
    case turnStarted(chatId: String, turnId: String, model: String)
    case llmCompleted(turnId: String, finishReason: String, usage: Usage?)   // 02 の Usage を再利用
    case toolCallStarted(turnId: String, callId: String, name: String, arguments: JSONValue)
    case toolCallFinished(turnId: String, callId: String, isError: Bool,
                          resultBytes: Int, durationMs: Int)                  // result 本体は ChatStore 側が持つ
    case turnSettled(turnId: String, iterations: Int, cumulativeUsage: Usage)
}

// Sources/Services/Chat/TraceSink.swift
public protocol TraceSink: Sendable {
    func emit(_ event: ChatTraceEvent)   // fire-and-forget。ループを絶対にブロックしない
}
```

- **注入点は ChatViewModel の既存の継ぎ目に1対1で対応**(調査で確定した行):
  send ループ開始 :124(turnStarted)、`.completed` 受領 :159-163(llmCompleted — usage 計上 :173-178 と同所)、
  execute の callTool 前後 :289(toolCallStarted/Finished)、settled :189-192(turnSettled)。
  LLMClient(LLMClient.swift:18-37)は**触らない** — トレースは「ループの観測」であって
  「LLM ワイヤの観測」ではないので、抽象の外側(ChatViewModel)に置く。
- 第一実装は2つ: `OSLogTraceSink`(subsystem `dev.gigun.mcphost`, category `"chat-trace"` —
  既存規約に乗る。next-directions の simctl E2E 自走検証にもそのまま効く)と、ChatStore への
  書き込み(こちらは既に T6 計画がイベントと同型のデータを持つので、Sink 経由に一本化するか
  ChatStore 直書きのままにするかは T6 実装時に判断してよい)。
- 将来: `ProxyTraceSink` は**作らない**。プロキシ段階ではサーバー側が全リクエストを見るので
  クライアント発トレースは不要 — seam の将来価値は「ローカル分析の出力先差し替え(SQLite/
  ファイル/デバッグ UI)」であり、これで十分。

**付随: UI 資源ツール結果のフル JSON(≈8,000 tok/ターン)の要約化 → 今は据え置き(02 §4 の JSON 採用を維持)**

- 正しさが先: モデルが結果本体を参照するケース(「3番目の todo の期限は?」)が現実にあり、
  カードは app-only の refresh で LLM と独立に生きている(論点2)ため「カードが見せるから LLM は
  要約でよい」は成立しない — LLM はカードを読めない。
- コスト実測が先: TraceSink の `resultBytes` + usage で「UI 資源ツール結果が実際に何 tok/何円
  食っているか」を取ってから、閾値ベースの切り詰め(例: structuredContent の tasks 配列を N 件+
  件数サマリに丸める)を検討する。最適化を観測より先にやらない。
- 可逆性: role:"tool" content の組み立ては execute の1箇所(:292-303)なので、後から要約器を
  挟むのは軽い。逆に今要約して「モデルが答えられない」退行を出すと原因切り分けが重い。

**可逆性: 高。** protocol 1つ+enum 1つ+呼び出し5箇所。捨てるのも差し替えるのも局所。
唯一半不可逆なのは「クライアントから外部へデータを出す」選択で、それを**しない**のが本決定。

**ボツ案:**
- **今から Langfuse iOS(クライアント直送)**: 上記の通りデータ持ち出しの先行コミット。BYOK キーと
  会話を第三者 SaaS に並べる構図はプライバシー説明責任も先食いする。却下。
- **OTel Swift SDK を今入れる**: 依存が重く(gRPC/protobuf)、単一ユーザーのローカル分析には
  過剰。seam があれば後から Sink 実装1個で足せる。却下。
- **LLMClient をデコレータでラップしてトレース**: LLM ワイヤしか見えず tool 実行・iteration が
  取れない。観測したいのはループなので却下。
- **結果の即時要約化(LLM へは要約のみ)**: 正しさの退行リスクをコスト実測なしで取ることになる。却下(実測後に再訪)。

## 4. 実装ステップ(すべてコード変更は本文書の合意後)

- **F1(即修正・論点1)**: AppsServerProxy.mcpArguments nil→`[:]`、decodeArguments の空畳み込み削除+
  壊れ JSON はツール未実行で role:"tool" エラー、swift-testing 3本。
- **F2(論点2)**: CardEmbed 生成条件に `isError != true`。docs/caldav-feedback.md に提案1件追記。
- **F3(論点3・T6 と同時)**: Kernel/Tracing/ChatTraceEvent + Services/Chat/TraceSink +
  OSLogTraceSink、ChatViewModel の5注入点。
- 判断ゲート:
  - [ ] F1 後、実機で「todoを見せて」が1回で成功し、カードに初回から4件入る(追加演出なし)
  - [ ] F3 後、1ターンの resultBytes/usage が unified log で読める → 要約化の再訪判断材料

## 5. 決定サマリ

1. **arguments は常に JSON object としてワイヤに載せる(省略しない)** — 担保点は
   AppsServerProxy.mcpArguments(nil→`[:]`)。仕様は optional だが TS SDK 系サーバーが実質 `{}` を
   要求するため、汎用ホストの唯一堅牢な既定。壊れ JSON は `{}` に化かさずモデルへエラー返却。
2. **鮮度モデルは現行維持**: ホストは spec MUST の初回 tool-input→tool-result 配送のみ、以後は
   カード自己 refresh(caldav カードの設計と一致)。isError 結果ではカードを起こさない。
   「+ ボタンで同期」は事実無根(FAB はローカルドラフトのみ)、「追加」誤演出は論点1起因で
   カードの diff は契約通り。
3. **観測はホスト責務**。今は ChatStore + OSLog + TraceSink 1 seam のみ設計、Langfuse/OTel は
   LLM プロキシ段階でサーバー側。UI 資源ツール結果のフル JSON はコスト実測が出るまで維持。

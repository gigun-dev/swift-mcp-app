# 次セッションの方向性(2026-07-15 第2版: コア価値を「iOS 汎用 MCP Apps ホスト」に転換)

> **位置づけ**: 恒久ドキュメント(セッション引き継ぎの正典)。セッション開始時にまず読む。
> **更新ルール**: 計画は消さない。完了は打ち消し線 + ✅、状況変化は該当箇所の直下に
> `> **YYYY-MM-DD 更新:** ...` の引用ブロックを積層する。大きな節目で全体を棚卸しする。
> 時系列の生記録は docs/log.md に追記(追記専用アーカイブ)。運用は caldav 側と同一。

**現在地(2026-07-16)**: コア価値は「**iOS 汎用 MCP Apps ホスト(路線B)**」。
**P0〜P2 完了 ✅ — 路線B は技術的に確立した。** caldav 本番の todos カードを
WKWebView で素の HTML のまま描画し、OAuth 接続 → カード内 complete → tools/call →
再描画の往復まで実機/シミュレータで実証済み(判断ゲート全項目 YES)。
**次は P3(チャット + LLM tool-use ループ)**。

転換の経緯(2026-07-15): 初版の「契約のネイティブ SwiftUI 描画(路線A)」から転換。
caldav 側 E-2 が本番検証込みでクローズし、todos v3 / agenda の検証済みインタラクティブ UI
(ext-apps 製・計約7,500行)がサーバー側に存在する今、ネイティブ再描画は二重実装になる。
Swift 側の最大の付加価値は「モバイルで MCP Apps を動かすホスト基盤」(≒ claude.ai モバイルの
自作版)。リサーチで **Swift/iOS のオープンな MCP Apps ホストは存在しない(Claude iOS は
クローズド)= 本アプリが初のオープン実装**と判明(下記「参照スタック」節・移植元は公式 ext-apps)。

**確定事項(2026-07-15)**:
- 個人開発。評価観点は重視しない。提出は repo + プレゼン想定。
- 最小 iOS バージョン: 授業指定が無ければ **iOS 17+**。
- 雛形: **XcodeGen(project.yml)+ Kernel/Services はローカル SwiftPM パッケージ**
  (`swift test` が Xcode なしで回り `make check` と相性が良い)。

**未確定**:
- GitHub リモート(public/private)を作るか

**次の優先順位**:
1. ~~**P0: プロジェクト雛形** — XcodeGen + ローカル SwiftPM パッケージで
   Kernel/Services/Features の3レイヤー骨格 + swift-sdk 依存追加 + Makefile
   (`make check` = swift build + swift test)。~~ ✅
   > **2026-07-15 更新:** 完了。swift-sdk 0.12.1(`from:` 指定)。`make check` green・
   > `make app`(シミュレータ)BUILD SUCCEEDED。`CODE_SIGNING_ALLOWED: NO` のため
   > 実機ビルドが要る時点(P1 の OAuth 実機検証など)で署名設定の見直しが必要。
2. **P1: 接続(MVP フェーズ1)** — OAuth 2.1(ASWebAuthenticationSession +
   swift-sdk の認可フロー)→ 本番 /mcp へ接続 → tools/list を画面表示。
   「繋がった」が最初のマイルストーン。トークンは Keychain。
   > **2026-07-15 更新:** 実装完了・**残るはユーザー実機での OAuth 実地検証のみ**。
   > 設計変更: カスタムスキームでなく **loopback リダイレクト**(swift-sdk の
   > `OAuthURLValidator` が https/loopback しか許可しないため。NWListener の一時ポート +
   > `ASWebAuthenticationSession(callbackURLScheme: nil)` = アプリ内シートのまま完結、
   > CFBundleURLTypes 不要)。caldav 側は workers-oauth-provider が RFC 8252 loopback の
   > ポート可変マッチを実装済みと裏取り済み(main レビューで確認)。
   > 実機検証の観点: シート表示→caldav ログイン→シート自動クローズ→tools/list 表示、
   > 2回目起動はブラウザなしで接続(Keychain 再利用)。失敗時は画面の赤字エラーを報告。
   > **2026-07-15 更新: P1 完了 ✅** — 実機・シミュレータ両方で OAuth→tools/list 到達。
   > デバッグで潰した4障害(NWListener EINVAL / preconnect でサーバー早畳み /
   > 認可の複数ラウンド非対応 / 無署名シミュレータの Keychain 失敗による 401 ループ)は
   > docs/log.md 2026-07-15 参照。残タスク: 実機での2回目起動(Keychain 再利用)確認のみ。
   > 副産物: MCPHOST_AUTOCONNECT=1 の自動接続 + unified log 計装で E2E をエージェントが
   > 自走検証できるようになった(以後の検証はこの経路を使う)。
3. ~~**P2: MCP Apps ホストスパイク(勝負どころ・判断ゲート)** — list-todos の `ui://` HTML を
   WKWebView で描画し、カード内操作 → tools/call → 再描画が往復するまで。~~ ✅
   > **2026-07-15 更新:** 設計完了(docs/design/01-apps-bridge.md)。S1〜S6 完了・
   > **判断ゲート全項目 YES で路線B確定**。実装は Kernel/AppsProtocol(JSON-RPC 封筒・
   > ui/* 型・JSONValue)、Services/AppsBridge(WebViewTransport の isTrusted インターセプタ・
   > AppsBridgeSession 状態機械・AppsServerProxy 素通し)、Features/AppCard + Spike。
   > 核心: WKWebView 主フレームで `window.parent === window` + `isTrusted` 方向判別 +
   > `stopImmediatePropagation` で、**caldav カードを1バイトも改変せず**双方向 postMessage 成立。
   > swift-sdk の落とし穴: callTool タプル版は structuredContent を捨てるため
   > RequestContext オーバーロードを使用。UX 修正済み(ダブルタップズーム無効・カード全画面)。
   > **未対応(P3 送り)**: focus zoom は caldav 側の文字サイズ改善で(docs/caldav-feedback.md)。
   > size-changed 追従(チャット内インラインカード)/ CSP meta 注入 / open-link 配線 /
   > world 分離 / AppsBridgeSession の protocol 抽象化テスト は P3 の堅牢化で。
4. **P3: チャット(MVP フェーズ3)← 次はここ** — LLM の tool-use ループ
   (tools/list → ツール定義変換 → tools/call)。ツール結果の `ui://` カードを
   チャット内にインライン描画(**AppsBridgeSession / AppCardView は P2 で完成済み・再利用**。
   ここで size-changed 追従を活かした複数カードのインライン配置を実装)。BYOK(設定画面+Keychain)。
   接続確立は P1 の MCPConnection / LoopbackOAuth… を再利用(TodosCardSpikeView が実例)。
   focus refetch(refresh-todos, `visibility:["app"]`)を LLM ツール一覧から除外する
   確認(apps.mdx:400 の MUST)は**このフェーズで必須**(P2 スパイクは LLM 未配線だった)。

   **LLM 層の設計(2026-07-16 確定・ベンダー中立)**:
   - **プロバイダ中立の `LLMClient` プロトコル**(`Services/LLM/`)にメッセージ・ツール定義・
     tool-use ループを一度だけ書く。MCP tools/list↔ツール定義・tool_use↔tools/call の
     変換はここに集約。→ CLAUDE.md ビジョン1(エンドポイント1箇所抽象・SaaS プロキシ差し替え)。
   - **第一アダプタは OpenAI 互換(`/chat/completions` + `tools`)**。base URL + モデル名 +
     キーの差し替えだけで OpenRouter / Together / Groq / ローカル(Ollama/LM Studio)/ 各社の
     OpenAI 互換エンドポイントに繋がる = 授業フェーズでベンダーロックしない。Anthropic ネイティブ
     アダプタは第二として後から足す(中立プロトコルがあるので可逆)。Vercel AI SDK は不採用(JS 前提)。
   - **コスト効率は第一級の価値(ユーザー方針)**: BYOK で API 従量なのでコストが効く。
     既定は軽量モデル(Haiku / Gemini Flash-Lite 級)を積極採用。設計上気にする点:
     (a) モデルは設定で差し替え可・既定を軽量に、(b) tool-use ループは毎ターン tools/list
     スキーマ(caldav ≈18 ツール)を送るのでトークン費が乗る → system prompt を痩せさせる・
     必要ならツール絞り込み、(c) トークン/コストの可視化(使用量表示)を検討。
     ※ 具体的なモデル ID・料金は実装時に claude-api スキルで裏取りする(記憶で書かない)。

   **実装ステップ(設計 docs/design/02-chat-llm.md §8。T1〜T7)**:
   - ~~T1: Kernel/LLMProtocol + ChatModel(OpenAI 互換ワイヤ型・ToolCallAccumulator・
     ToolVisibility 純関数・チャットドメイン型 + swift-testing)~~ ✅
     > **2026-07-16 更新:** T1 完了。`Sources/Kernel/LLMProtocol/`(ChatCompletion・
     > ChatCompletionChunk・ToolCallAccumulator・ToolVisibility)+ `Sources/Kernel/ChatModel/`。
     > Kernel 依存ゼロ厳守(import Foundation のみ)。swift test 41 件 green。
     > 設計に無く実装で決めた点(レビュー済み): FinishReason はカスタム Codable(.other 連想値)/
     > visibility 仕様違反データは既定 `["model","app"]` へフェイルセーフ(ツールが理由不明に
     > 消えるより残す)/ ToolCallAccumulator は index 昇順整列・id/name 後勝ち・欠落は空文字で可視化。
   - ~~T2: Services/LLM(LLMClient + OpenAICompatClient SSE + MCP→OpenAI ツール変換 +
     AppsServerProxy の app 発 tools/call 拒否 = apps.mdx:401 MUST)~~ ✅
     > **2026-07-16 更新:** T2 完了。`Sources/Services/LLM/`(LLMClient・OpenAICompatClient・
     > SSELineParser・ToolConversion)+ AppsServerProxy に setTools/拒否を追加。swift test 60 件 green。
     > **本番 OpenAI(gpt-5.4-mini)ライブ検証済み**: 単発補完(reason=stop・usage 取得)+
     > tool_calls(get_weather の arguments が有効 JSON・usage 取得)が end-to-end で通った。
     > **発見した実バグ(修正済み)**: `URLSession.AsyncBytes.lines`(Swift 6.3/macOS 26)が
     > **本当に空の行を yield しない** → SSE のイベント境界(空行)が検出できず全 data が連結され
     > DecodingError。→ consumeSSE を `.lines` 非経由の自前 \n 分割(空行保持・末尾 \r 除去)に置換。
     > ⚠️ iOS 実機/シミュレータの実行時でも同挙動かは未確認(macOS の swift test 上での発見)。
     > T5 の実機カード検証時に SSE が実機で流れることを併せて確認する。BYOK キーは `.env`(git 管理外)。
   - ~~T3: Services/Chat/ChatViewModel(tool-use ループ)~~ ✅
     > **2026-07-16 更新:** T3 完了。`Sources/Services/Chat/`(MCPToolExecuting 抽象 +
     > `extension AppsServerProxy: MCPToolExecuting {}` 本体追加なし・ChatViewModel の
     > tool-use ループ)。swift test 66 件 green。**本番 gpt-5.4-mini + フェイク executor で
     > 自走確認**: 1周目 .toolCalls(get_weather 呼出)→ 2周目 .stop(最終テキスト)。
     > 表示 turns と wire messages を分離・複数 tool_call は TaskGroup 並行・role:tool は
     > tool_call_id 昇順で安定・ツール失敗はステップ failed + role:tool にエラーで**ループ継続**・
     > 最大反復8で打ち切り。caldav 実接続(OAuth)は Features 未実装のため T5 送り。
   - ~~T4: Features/Chat + Settings(チャット主画面・BYOK 設定・OAuth 実接続配線)~~ ✅
     > **2026-07-16 更新:** T4 完了(人手 E2E まで通過)。`Sources/Features/Settings/`
     > (LLMSettingsStore=キーは Keychain・baseURL/model は Defaults・env 注入
     > MCPHOST_LLM_KEY/_BASEURL/_MODEL・既定 model=gpt-5.4-mini / SettingsSheet=プリセット chips)
     > + `Sources/Features/Chat/`(ChatHomeViewModel=OAuth→setTools→toolDefinitions→
     > OpenAICompatClient→ChatViewModel / ChatHomeView / ChatBodyView=吹き出し・ツールステップ・
     > コスト表示)。通常起動を ChatHomeView に差し替え。カードは非表示(T5)。
     > **実機ランタイム E2E 成功(シミュレータ iPhone 17 Pro)**: OAuth 実接続(書込スコープ同意)→
     > tools=19 → **LLM 定義 17 件(visibility:["app"] の refresh-todos/refresh-events 2件が除外 =
     > apps.mdx:400 MUST を実機で実証)** → チャット「List todo」で 🔧 list-todos 実行 →
     > **ストリーミング応答**(= T2 の `.lines` バグ修正が iOS でも有効・⚠️ 解消)→ 実 caldav
     > データ4件を要約。コスト表示動作(≈8,818 tok/ターン)。
     > **観測されたコスト論点**: 毎ターン ≈17 ツールのスキーマ送信でトークンが乗る(設計 §6 の
     > 予期どおり)→ T7/最適化の対象。**軽微 UI**: model chip が小さく潰れて見える(後で詰める)。
     > レビュー保留(モック逸脱): 設定 chips に OpenAI 追加/接続前ゲート画面はモック外で新設。
   - ~~T5: インラインカード(ツール結果の ui:// カードをチャット内描画 + 往復)~~ ✅
     > **2026-07-16 更新:** T5 実装 + 実機 E2E 成功。`Sources/Features/Chat/InlineCardView.swift`
     > (InlineCardHost/Registry = LazyVStack スクロール再生成に耐える生存管理)+ ChatViewModel の
     > uiResourceURIs 注入で UI 資源ツール結果を turn.cards に記録。実機で todos カードがインライン
     > 描画・高さ追従・カード自己 refresh 往復を確認。
     > **実運用で3論点が表面化 → fable 設計(docs/design/03)→ F1/F2 修正で解消**:
     > - 論点1(バグ): 空引数 `{}` を nil に畳んで送信 → swift-sdk が arguments 省略 → TS SDK の
     >   zod object が undefined 拒否 → list-todos 失敗。F1: `AppsServerProxy.mcpArguments` で
     >   nil→`{}` 正規化・decodeArguments の空畳み込み削除・壊れ JSON はモデルにエラー返却。
     > - 論点2: 空 tool-result が prev=[] を確立 → 自己 refresh で全件「追加」誤演出。F2: isError
     >   結果ではカードを起こさない。「+ ボタンで同期」は事実無根(FAB はローカルドラフトのみ)。
     > - 論点3: 観測はアプリ責務。TraceSink 1 seam を T6 と同時(F3・未実装)。Langfuse はプロキシ段階。
     > F1/F2 適用後、実機で「todoを見せて」が1回成功・初回から実データ・追加演出なしを確認(判断ゲート通過)。
     > swift test 76 件 green。残: カード内 complete の write 往復目視 / モデルが list-calendars を
     > 先呼びする癖(system prompt 誘導候補)。
   - T6: 履歴永続化 + サイドバー(+ F3 TraceSink)← 次はここ / T7: コスト表示
5. **P4(余力)**: (a) todos 一覧をネイティブ SwiftUI でも実装し「同じ契約の二方式描画」を
   対比(路線C要素・プレゼンの主張になる)、または (b) caldav 以外の MCP サーバー接続デモで
   汎用性を示す。初版の P4(アジェンダ)はホスト経由なら agenda カードがそのまま動くため吸収。

<!-- session-head-end: ここまでが SessionStart フックで自動注入される「頭」。 -->

## 路線の定義(転換の記録)

- **路線A(初版のコア価値・撤退先として保持)**: caldav の TodosViewModel / EventsViewModel
  契約を SwiftUI でネイティブ描画する「契約クライアント」。共有カーネルの第3消費者。
  E-2 完成前(サーバー側に UI が無かった頃)の前提に基づく構想で、MCP Apps 対応済みの
  現在は二重実装に近い。ただし P2 のスパイクが失敗した場合の撤退先として計画は消さない。
- **路線B(現行コア価値)**: 任意の MCP サーバーに OAuth で繋ぎ、チャットで LLM がツールを叩き、
  結果の `ui://` カードを WKWebView サンドボックス + postMessage⇔MCP ブリッジで描画・
  双方向操作できる **iOS 汎用 MCP Apps ホスト**。caldav は最初の(最良の)接続先。
- **路線C(余力)**: B の基盤の上に看板画面1つだけネイティブ SwiftUI(P4a)。

## MCP Apps ホスト実装の参照スタック(2026-07-15 リサーチ確定)

前提事実: MCP Apps の正式 SEP は **SEP-1865**(初版記載の SEP-1310 は先行提案で誤り)。
拡張 ID `io.modelcontextprotocol/ui`、初の公式 MCP 拡張として 2026-01-26 に出荷。
**Swift/iOS のオープンなホスト実装は存在しない**(swift-sdk に apps サポート無し・issue も無し。
Claude iOS は対応済みだがクローズド)→ 本アプリが初のオープン実装 = プレゼンの主張そのもの。

移植元(読む順):
1. **公式 [ext-apps](https://github.com/modelcontextprotocol/ext-apps)**(正典):
   `docs/overview.md`(三者アーキテクチャ)→ `specification/2026-01-26/apps.mdx`(規範)→
   `src/spec.types.ts`(メッセージ型 → Kernel の Codable に写経)→ `src/app-bridge.ts`
   (AppBridge: connect/sendToolInput/sendToolResult/setHostContext)→
   `src/message-transport.ts`(PostMessageTransport — WKScriptMessageHandler 版に置換する箇所)→
   `examples/basic-host`(E2E 配線)→ `docs/testing-mcp-apps.md`
2. [mcp-ui](https://github.com/MCP-UI-Org/mcp-ui) `@mcp-ui/client` — ホストアダプタの
   エッジケース参照(依存にはしない)
3. モバイル UX: https://casys.ai/blog/mcp-apps-mobile-ux-patterns(~300–360px viewport・
   requestDisplayMode・コンパクトカード)

ブリッジプロトコル要点(WKWebView 実装の設計入力):
- JSON-RPC 2.0 over postMessage(iOS では WKScriptMessageHandler + evaluateJavaScript)。
  ホストが常に主導権・View は untrusted。
- 発見: ツールの `_meta.ui.resourceUri` + `visibility: ["model","app"]`(非 model ツールは
  LLM のツール一覧から除外)。HTML は tools/call 前に `resources/read` でプリフェッチ・キャッシュ。
- ライフサイクル: View→`ui/initialize` → ホストが hostContext(テーマ CSS 変数・locale・
  displayMode・containerDimensions)を返す → `ui/notifications/initialized` →
  `tool-input`/`tool-input-partial`/`tool-result`/`tool-cancelled`。破棄前 `ui/resource-teardown`。
- View→Host: `tools/call`(サーバーへプロキシ)・`resources/read`・`ui/open-link`・
  `ui/message`(チャットへ注入)・`ui/request-display-mode`・`ui/update-model-context`。
- サイズ: host が containerDimensions を渡し View が `ui/notifications/size-changed` を返す。
- セキュリティ: `_meta.ui.csp`(connectDomains 等)をホストが強制。Web ホストの二重 iframe
  サンドボックスに対し、iOS は WKWebView 自体が外殻 — CSP `<meta>` 注入 +
  WKContentRuleList でネットワーク遮断 + 非永続 WKWebsiteDataStore + ナビゲーション横取り。
- 検証: ext-apps のサンプルサーバー(npx)+ basic-host との挙動パリティ。

## 参照(契約・設計の正は caldav 側)

- MCP Apps サーバー実装(ホストが相手にする側): caldav `src/presentation/mcp/server.ts`
  (`registerAppResource` / `registerAppTool`、mimeType `text/html;profile=mcp-app`、
  `_meta.ui.resourceUri` + 後方互換 `_meta["ui/resourceUri"]`)と
  `src/presentation/mcp/ui/`(todos-entry / agenda-entry。`@modelcontextprotocol/ext-apps` の
  App を使用 — ホスト側はこの App と会話するブリッジを実装する)
- ツールスキーマ・DTO: caldav `src/presentation/mcp/server.ts` /
  `docs/modeling/12-vevent-agentic.md`(Event DTO / EventsViewModel / Task DTO 系)
- OAuth の暗黙契約: caldav `docs/next-directions.md` 方向性 E
  (DCR `token_endpoint_auth_method:"none"` / Accept: text/event-stream)
- UI 文法(路線A撤退時・P4a 用): caldav `docs/modeling/ui-mockups/`(todos-refined-v3 / agenda-v1)
- SaaS 構成方針(LLM プロキシ・課金): caldav docs/next-directions.md「Swift コンパニオン」節
- caldav 側依存: **R-6(OAuth scope 分離)** — 済(2026-07-15 caldav 側でクローズ済みと確認。
  現状の接続は scope 未指定で通る。write scope の明示対応は将来)。
- **caldav へのフィードバック**: `docs/caldav-feedback.md`(ネイティブホストで表面化した
  caldav 側対処事項。focus zoom の元凶 = `.d-notes` 13px / complete の視覚フィードバック)。

## P2 で確立した実装(P3 以降で再利用する土台)

- **Kernel/AppsProtocol**: JSON-RPC 封筒 / ui/* メッセージ型 / JSONValue(caldav 非依存・純粋)。
- **Services/AppsBridge**: WebViewTransport(isTrusted インターセプタ)/ AppsBridgeSession
  (状態機械・outbox・MainActor 隔離)/ AppsServerProxy(_meta.ui 解決・素通し・HTML キャッシュ)。
- **Features/AppCard**: AppCardView(サンドボックス WKWebView)/ AppCardWebViewFactory
  (ContentRuleList 全遮断・非永続ストア・ダブルタップズーム無効)。
- **Features/Spike**: TransportSpikeView(MCPHOST_SPIKE=transport)/ TodosCardSpikeView
  (=todos。P1 接続再利用→カード1枚の実例)。P3 のチャットはこの配線を複数カードに一般化する。
- **検証基盤**: MCPHOST_AUTOCONNECT=1 / MCPHOST_SPIKE=<name> の起動切替 + unified log
  (subsystem `dev.gigun.mcphost`)。エージェントが simctl だけで E2E 自走検証できる。

## 据え置き・起票のみ

- **P3 の堅牢化(P2 で意図的に送りにした項目)**: size-changed 追従を活かしたチャット内
  インラインカード / CSP `<meta>` 注入(注入純関数の置き場は Kernel に確保済み)/
  `ui/open-link` の Features 側ハンドラ配線 / WKContentWorld 分離 / AppsBridgeSession の
  protocol 抽象化による状態遷移テスト / MCP.Value 経由のロスレス性を send() 直叩きに寄せる判断。
- LLM プロキシ(Workers)+ メータリング/課金 — SaaS 化フェーズ(授業スコープ外)
- 月/週ビュー(アジェンダの粒度追加)— 画面が広い Swift ではカードより自由度が高い
- Push/ローカル通知(サーバー VALARM との関係整理が先)
- P4a(ネイティブ二方式描画)/ P4b(他 MCP サーバーデモ)— どちらを取るかは P3 後に判断

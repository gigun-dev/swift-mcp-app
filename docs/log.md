# log(追記専用アーカイブ)

- 2026-07-15: リポジトリ作成(caldav-companion → swift-mcp-app にリネーム)。方針 README。
- 2026-07-15: caldav から開発基盤を移植(CLAUDE.md / .claude/rules/comments.md / SessionStart フック+next-directions 正典 / log)。

## 2026-07-15 コア価値の転換(路線A→B)

- ユーザーとすり合わせ: 個人開発・評価観点は重視せず・提出は repo+プレゼン・iOS 17+(指定なければ)。
- caldav 側の現状を再把握: E-2(todos MCP App)本番検証込みクローズ、ext-apps 製カード計約7,500行、
  R-6(OAuth scope 分離)が第三者クライアント前提として優先度上昇済み。
- 判断: ネイティブ契約描画(初版コア価値・路線A)はサーバー側 UI 完成後の今では二重実装。
  コア価値を **iOS 汎用 MCP Apps ホスト(路線B)** に転換(ユーザー確定)。
  P2 に WKWebView+ext-apps ブリッジのスパイクを判断ゲートとして置き、失敗時は路線Aへ撤退。
- CLAUDE.md / README / next-directions(第2版)を書き換え。
- 既存の Swift/iOS MCP Apps ホスト事例と ext-apps ブリッジプロトコルのリサーチを subagent で開始。

## 2026-07-15 リサーチ完了 + P0 雛形完了

- リサーチ: Swift/iOS のオープンな MCP Apps ホストは存在せず(Claude iOS はクローズド)、
  本アプリが初のオープン実装になる。正式 SEP は SEP-1865(初版記載の 1310 は誤り・修正済み)。
  移植元は公式 ext-apps 一式(spec.types.ts / app-bridge.ts / basic-host)。
  詳細は next-directions「MCP Apps ホスト実装の参照スタック」節。
- P0(implementer 委譲): ルート SwiftPM パッケージ(Kernel/Services + swift-testing)、
  XcodeGen(MCPHost・iOS 17+・.xcodeproj は git 管理外)、Makefile(check/gen/app)。
  swift-sdk 0.12.1。make check green・シミュレータビルド成功。
  注意点: swift-sdk の product 参照はパッケージ識別子 "swift-sdk"(URL 末尾)で指定、
  CODE_SIGNING_ALLOWED=NO(実機が要る時点で見直し)。

## 2026-07-15 P1 実装(OAuth 2.1 + tools/list)

- implementer 委譲で実装: KeychainTokenStorage(TokenStorage の Keychain 実装・
  account=サーバー URL で複数サーバーの芽)、MCPConnection(caldav 非依存の接続層)、
  LoopbackOAuthAuthorizationDelegate(NWListener + ASWebAuthenticationSession)、
  ConnectionView/ViewModel(素朴な開発用画面)。
- 設計変更: swift-sdk の OAuthURLValidator がカスタムスキームを弾くため
  loopback リダイレクトに変更(詳細は delegate 冒頭コメント)。
- main レビュー: caldav 側 workers-oauth-provider の RFC 8252 loopback ポート可変マッチを
  node_modules の実装で裏取り。defer による connection/listener の早期 cancel が
  200 応答の送信と競合しハングしうる問題を発見・修正(cancel を send 完了ハンドラへ移動)。
- make check / make app / make device すべて green。実機での OAuth 実地検証はユーザー待ち。

## 2026-07-15 OAuth 実機デバッグ: NWListener → BSD ソケットへ

- 実機で「接続」→ POSIXErrorCode 22(EINVAL)。ポート .any → 明示ポートでも同じ。
- macOS 最小再現(scratchpad/nwtest.swift): 素の NWListener(using:on:) 含め全パターン EINVAL、
  一方 BSD ソケット直(socket/bind/listen)は成功。NWListener の失敗原因は未特定のまま、
  動作実証済みの最下層に乗り換える判断。
- Services/OAuth/LoopbackCallbackServer.swift(BSD + DispatchSource)を新設。UIKit 非依存に
  なったので swift test で実挙動(bind→本物の GET→URL 復元・キャンセル)をテスト化
  (NWListener 版は Features 層でテスト不能 → 実機で初めて発覚した反省)。
- delegate は提示とキャンセルだけに痩せた。実機へ再インストール済み・ユーザー再検証待ち。

## 2026-07-15 P1 完了までのデバッグ(シミュレータで4障害を連続特定)

観測手段を先に整備したのが効いた: MCPHOST_AUTOCONNECT=1(起動環境変数で自動接続)+
unified log 計装(subsystem dev.gigun.mcphost)+ simctl screenshot + Workers ログ
(cloudflare-observability MCP)+ curl での OAuth フロー完全再現。

1. **preconnect でサーバー早畳み**: WebKit の投機的事前接続(データなしで close)を
   不正リクエスト扱いしてサーバーごと畳んでいた → 空/不正接続は読み捨てて listen 継続。
2. **accept ループの起動が waitForCallback 内**: 登録前に届いたリクエストが応答されず
   ブラウザが 60 秒ハング(テストが検出)→ accept ループを start() 時点で起動 +
   先着結果の保持箱(finishedResult)。
3. **認可の複数ラウンド非対応**: swift-sdk は1接続で認可を複数回実行しうる
   (POST/SSE の2経路 401・リトライ)。1回目のコールバックで listen ソケットまで
   閉じていたため2回目が notStarted に化けた → 成功時もサーバーを畳まない
   (畳むのは cancel/deinit のみ)。回帰テスト追加(計7件)。
4. **無署名シミュレータの Keychain 失敗 → 401 無限ループ(真打ち)**: curl 再現で
   サーバー正常・Workers ログで「トークン交換 200 なのに POST /mcp 401×10」を確認 →
   アプリがトークンを付けていない → SecItemAdd が -34018(entitlement 欠如)で無言失敗、
   load() 常に nil。実機は署名済みで発症せず(「実機では動く」の説明)→
   メモリキャッシュを一次層に、Keychain はベストエフォート永続化に格下げ+失敗をログ化。

他: Launch Screen 宣言漏れ(INFOPLIST_KEY_UILaunchScreen_Generation)でレターボックス
起動になっていたのを修正。ConnectionView に onAppear 自動接続フック。

**P1 完了**: 実機・シミュレータ両方で OAuth(loopback)→ tools/list 表示を確認。

## 2026-07-15 P2 スパイク S1+S2: postMessage ブリッジ疎通 実証 ✅

- S1(Kernel/AppsProtocol): JSONValue(自前・MCP.Value 不採用=Kernel 依存ゼロ制約 +
  Value の data URL 自動変換が素通しを弱めるため)、JSON-RPC 封筒、ui/* 最小集合、
  IncomingViewMessage 2レーン。swift-testing 8ケース(structuredContent の未知フィールド
  ロスレス保存を明示テスト)。全16テスト green。
- S2(Services/AppsBridge/WebViewTransport + Features/Spike): 設計 §1 の
  「isTrusted 判別インターセプタ(documentStart 注入)」実装。MCPHOST_SPIKE=transport で
  疎通確認画面。**main が自分で simctl 検証**: スクショで3仮説すべて可視を確認。
  1. View→Host 受信 method=echo(parent===window)
  2. mini view に received isTrusted=false(合成 MessageEvent 配送)
  3. self-loopback: none(stopImmediatePropagation の登録順)
  caldav カードを1バイトも改変せず素の HTML で成立。設計文書と食い違いゼロ。
- **判断ゲート: 路線B続行**(最大リスク消滅)。S3(状態機械)→S4(実カード)→S5(往復)へ。
- 申し送り: actor AppsBridgeSession 化時、WKWebView 操作の MainActor 隔離を S3 で設計に織り込む。

## 2026-07-15 P2 スパイク S3-S6 完了: MCP Apps ホスト成立(判断ゲート全 YES)✅

- S3 AppsBridgeSession(actor + State + outbox)、S4 AppsServerProxy(_meta.ui 解決 +
  HTML プリフェッチ + tools/call/resources/read 素通し)、S5 往復、S6 サンドボックス
  (ContentRuleList 全遮断・非永続ストア・navigation/window.open 封じ)+ AppCardView。
- swift-sdk の落とし穴: callTool のタプル版は structuredContent/_meta を捨てるため
  RequestContext<CallTool.Result> オーバーロードを使用(todos カードは structuredContent
  を描画に使う)。readResource は result-level _meta を落とすが _meta.ui は content-level
  なので実害なし。
- MainActor 隔離: WebViewTransport.deliver 内で @MainActor deliverOnMain へホップ。
- **main が simctl + log stream + screenshot でゲート7項目を自己検証**:
  initialize 到達 / initialized 前送信ゼロ(outbox 退避→flush)/ 実データ描画 /
  complete 往復(update-todo ×32 全応答)/ 全遮断下で動作 / size-changed 追従(337→386)。
  caldav 本番の todos カードが素の HTML のまま動いた。**路線B技術的に完全成立**。
- 残 UX 課題(次コミットで対応): カード幅が狭い / WebKit のダブルタップ遅延で複数回押し。

## 2026-07-15 P2 スパイク UX 修正(カードサイズ・タップ遅延)+ 締め

- 「3回押さないと反応しない」= WebKit のダブルタップ(ズーム)判定による ~350ms click 遅延。
  scrollView の zoom を 1:1 固定 + numberOfTapsRequired==2 のジェスチャ認識器を無効化 →
  単発 click 即発火で解消(AppCardWebViewFactory)。
- 「カードが小さい/縦幅足りない」= size-changed 追従(P3 のチャット内インラインカード向け)が
  単カード全画面デモに不適。ext-apps は html を max-content 計測した高さを返すが、caldav カードは
  状態でコンテンツが伸びるため枠に収まらずクリップされた。→ スパイクは WKWebView 内部スクロール
  有効化(factory に scrollEnabled 引数)+ カードを利用可能領域いっぱいに固定。追従は P3 に残す。
- 「complete が3段階に分かれる」= ログで 1タップ=1 update-todo 往復・重複ゼロを確認 →
  ブリッジは正常。多段は caldav todos v3 の becoming-done 演出 × 本番往復レイテンシ(0.6-2.5s)。
  caldav 側の挙動でホストは忠実に描画しているだけ(ユーザーの見立て通り)。
- **P2 完了**: 判断ゲート全項目 YES + UX 修正済み。路線B(iOS 汎用 MCP Apps ホスト)確立。

## 2026-07-15 ズーム方針の是正 + caldav フィードバック起票

- ユーザー指摘: focus zoom はズームロックでなく文字サイズ改善で直すべき(小さすぎる文字が
  根本)。ズームロックはピンチズーム=アクセシビリティも殺す。→ 同意。
- ホスト側: minimumZoomScale=maximumZoomScale=1 のロックを撤回(ボツ案としてコメント保存)。
  残す介入はダブルタップ・ツー・ズーム認識器の無効化のみ(タップ遅延対策 + ダブルタップズームが
  うざいというユーザー要望・ピンチズームは残す)。focus zoom はホストで触らない。
- caldav 側の根本原因を docs/caldav-feedback.md に起票: .d-notes(メモ textarea)が 13px で
  iOS focus zoom を踏む(.d-title は 16px で OK)。入力欄を 16px 以上にするのが正しい対処。
  claude.ai は iframe 外側で viewport を持つため隠れていた、ネイティブ WKWebView ホストで表面化。
- complete の視覚フィードバックの乏しさも caldav-feedback に記載(ホストは 1タップ=1往復で正常)。

## 2026-07-16 P3 T1: Kernel/LLMProtocol + ChatModel

- P3 設計(docs/design/02-chat-llm.md)を fable architect がレビュー・改稿(ドラフト起こしは main)。
  訂正6点の要: (1)LLMEvent 終端は `completed(FinishReason,[ToolCall],Usage?)` 1つに統合 —
  usage は finish_reason チャンクの後 `choices:[]` の追加チャンクで届くため 2終端だと取り逃す・
  パーサは choices[0] を仮定禁止、(2)apps.mdx:401 の app 発 tools/call 拒否 MUST が抜けていた
  (T2 で AppsServerProxy に追加)、(3)_meta は MCP.Metadata → Value→JSONValue 変換後 Kernel 純関数へ、
  (4)tools/call は既存 AppsServerProxy.callTool で足りる=新 API 不要、(5)スナップショット再訪は
  allowsContentJavaScript=false で JS 無効・ライブ WKWebView は上限付き降格。
- T1 実装(implementer 委譲・main レビュー): Kernel のみ・依存ゼロ(import Foundation)。
  - LLMProtocol: ChatCompletion(Request/Message/ToolDefinition/ToolCall/Usage/FinishReason)・
    ChatCompletionChunk(choices 空を許容=usage チャンク対応)・ToolCallAccumulator(index 昇順・
    id/name 後勝ち・欠落は空文字で可視化)・ToolVisibility(isModelVisible/isAppCallable、
    仕様違反データは既定 ["model","app"] へフェイルセーフ)。
  - ChatModel: ChatSession/ChatTurn/ToolCallStep/CardEmbed(永続化 DTO 兼用・JSONValue 再利用)。
  - swift test 41 件 green(Kernel 30 + Services 11)。コミット済み。次は T2(Services/LLM)。

## 2026-07-16 P3 T2: Services/LLM(SSE アダプタ)+ bytes.lines 空行バグ

- 実装(artisan 委譲・中断→ main 引き継ぎ・main レビュー): Sources/Services/LLM/ 4ファイル。
  - LLMClient(中立 protocol・LLMEvent{textDelta, completed(FinishReason,[ToolCall],Usage?)})。
  - OpenAICompatClient(URLSession.bytes の SSE 翻訳・stream_options include_usage 強制・
    400 で stream_options 外し1回リトライ・非2xx はボディ込み httpError)。
  - SSELineParser(SSE 行→data 抽出の純関数: 空行境界・data: 剥がし・複数行 \n 連結・コメント無視)。
  - ToolConversion(MCP tools/list → OpenAI ToolDefinition・visibility 除外 apps.mdx:400)。
  - AppsServerProxy に setTools()+ app 発 tools/call 拒否(apps.mdx:401・後方互換: 一覧未注入=全許可)。
- テスト(implementer 委譲): Tests/ServicesTests/LLMTests.swift。SSELineParser/ToolConversion/
  拒否/OpenAICompatClient(URLProtocol スタブ)。@Suite(.serialized) でスタブ handler 競合回避。
- **実バグ発見→修正**: `URLSession.AsyncBytes.lines`(Swift 6.3/macOS 26)が「本当に空の行」を
  yield しない("a\n\nb"→["a","b"])。SSE 境界=空行が来ず全 data 連結 → DecodingError。
  最小 AsyncSequence + 本番 OpenAI/gpt-5.4-mini ライブで二重再現。→ consumeSSE を .lines 非経由の
  自前 \n 分割(空行を "" で保持・末尾 \r 除去)に置換。SSELineParser は無変更(元から正しい)。
  ⚠️ iOS 実機ランタイムでの同挙動は未確認 → T5 実機検証で SSE が流れることを併せて確認する。
- ライブ検証(本番 OpenAI gpt-5.4-mini・キーは .env/git 管理外): 単発補完 reason=stop・usage(17/4/21)、
  tool_calls reason=toolCalls・get_weather arguments={"city":"東京"} 有効 JSON・usage(144/17/161)。
- swift test 60 件 green(既存 41 + LLM 19)。次は T3(ChatViewModel の tool-use ループ)。

## 2026-07-16 P3 T3: ChatViewModel tool-use ループ

- 実装(artisan 委譲・main レビュー): Sources/Services/Chat/。
  - MCPToolExecuting: ツール実行の最小抽象(callTool(name:arguments:JSONValue?)->JSONValue)。
    AppsServerProxy が同シグネチャを既に持つため extension で本体追加なし conformance。
    テストはスタブ executor に差し替え(ネットワーク/OAuth/swift-sdk なしでループ検証)。
  - ChatViewModel(@MainActor @Observable): tool-use ループ本体。
    - 表示 turns([ChatTurn]・UI 粒度)と wire messages([ChatMessage]・LLM へ毎回送る厳密系列)を分離。
    - textDelta 逐次反映 → completed で確定 → .toolCalls && !empty なら TaskGroup 並行実行 →
      role:tool を tool_call_id 昇順で安定積み戻し → 次周。.stop 等で settle。最大反復8で打ち切り。
    - usage 毎ターン計上(lastUsage/cumulativeUsage)。ツール失敗はステップ failed + role:tool に
      エラー文言でループ継続(1本の失敗で全体を殺さない)。ストリーム自体の失敗は継続不能→即エラー。
    - arguments(JSON 文字列)の空/"{}"/壊れは nil に寄せる(AppsServerProxy が nil=引数なし)。
- テスト: ChatViewModelTests(6件)。テキストのみ/単一/複数 tool_call/最大反復/失敗継続/system 注入。
- ライブ検証(本番 gpt-5.4-mini + フェイク get_weather executor・キー .env): 自走成功。
  turn1 .toolCalls(city=東京)→ turn2 .stop(最終テキスト)。usage cumulative 394/45/439。
- swift test 66 件 green(既存 60 + ChatViewModel 6)。次は T4(Features/Chat + Settings・UI 実装)。

## 2026-07-16 P3 T4: Features チャット主画面 + BYOK 設定 + OAuth 実接続配線

- 実装(artisan 委譲・main レビュー): Sources/Features/。
  - Settings/LLMSettingsStore: キー=Keychain(service dev.gigun.mcphost.llm・SecItem upsert 流儀)、
    baseURL/model=UserDefaults。env オーバーライド MCPHOST_LLM_KEY/_BASEURL/_MODEL(自走検証用)。
    既定 baseURL=OpenAI 公式・model=gpt-5.4-mini。
  - Settings/SettingsSheet: プリセット chips(OpenAI/OpenRouter/Groq/Together/Ollama/カスタム)で
    base URL 差し替え + 接続/モデルセクション。※各プリセット base URL の実在裏取りは未実施。
  - Chat/ChatHomeViewModel: 接続オーケストレータ(.needsSetup/.connecting/.ready(ChatViewModel)/.failed)。
    OAuth 接続(ConnectionVM/Spike 踏襲)→ AppsServerProxy.setTools → toolDefinitions(visibility 除外)
    → OpenAICompatClient → ChatViewModel 組み立て。痩せた systemPrompt(コスト)。MCPHOST_AUTOCONNECT 対応。
  - Chat/ChatBodyView + ChatHomeView: モック chat-v1.html 準拠(吹き出し・ツールステップ可視化・
    コスト表示=トークン数のみ・model chip・設定ボタン)。カードは非表示(T5)。
  - MCPHostApp: 通常起動の else を ChatHomeView に差し替え(SPIKE/AUTOCONNECT 温存)。
- 検証: make app BUILD SUCCEEDED / make check 66 件 green / シミュレータ install・launch 非クラッシュ。
- **未実施(人手 E2E・T4 の残作業)**: 実機/シミュレータで OAuth 対話(caldav changeme)+ 実 LLM
  チャット往復の目視。OAuth ブラウザシート操作は人手が要る。次はこれ → その後 T5(インラインカード)。
- モック逸脱(レビュー保留): 設定 chips に OpenAI 追加/接続前ゲート画面はモック外で新設。

## 2026-07-16 P3 T4 人手 E2E: 実機ランタイムでチャット往復成功

- シミュレータ iPhone 17 Pro に install、MCPHOST_AUTOCONNECT=1 + MCPHOST_LLM_KEY(.env)+
  MCPHOST_LLM_MODEL=gpt-5.4-mini で起動。OAuth 同意(書込スコープ)を人手で通過。
- 確認できたこと:
  - OAuth 実接続成功 → tools=19 取得。
  - **visibility 除外の MUST(apps.mdx:400)が実機で発火**: 19 → LLM 定義 17 件
    (refresh-todos/refresh-events = visibility:["app"] の2件が除外)。
  - チャット「List todo」→ 🔧 list-todos 実行 → **ストリーミング応答**が伸びる
    = **T2 の `.lines` 空行バグ修正が iOS ランタイムでも有効**(macOS swift test での発見が
    実機でも問題ないことを確認・next-directions の ⚠️ 解消)。
  - 実 caldav データ4件(追加へ1/テスト/test/新規)を取得・要約。ツールステップ可視化・
    コスト表示(このターン ≈8,818 tok・累計 32,364 tok)動作。
- コスト論点: 毎ターン ≈17 ツールのスキーマ送信でトークンが乗る(設計 §6 予期どおり)→ T7 で。
- 軽微 UI: model chip が小さく潰れて見える(後で詰める)。
- T4 完了。P3 のコア(チャット + LLM tool-use + 実 MCP)が実機で end-to-end 成立。次は T5(カード)。

## 2026-07-16 P3 T5 + F1/F2: インラインカード + 引数バグ修正

- T5 実装(artisan 委譲): Sources/Features/Chat/InlineCardView.swift(InlineCardHost/Registry で
  LazyVStack スクロール再生成に耐える生存管理・1カード=1セッション・高さ追従 scrollEnabled=false)。
  ChatViewModel に uiResourceURIs 注入 → UI 資源ツールの成功結果を turn.cards に CardEmbed 記録。
  CardEmbed に arguments 追加。ChatHomeViewModel が proxy 公開 + uiResourceURIs 生成。
- 実運用で3論点表面化 → fable が docs/design/03 に設計 → F1/F2 実装で解消(実機ログで機序確定):
  - 論点1(バグ確定・実機診断ログ): `list-todos args=null → 失敗` / `refresh-todos args={} → tasks4件`。
    機序4段(MCP 仕様 arguments optional × swift-sdk encodeIfPresent が nil 省略 × TS SDK zod object が
    undefined 拒否 × アプリ decodeArguments が {}→nil 畳み込み)。
    F1: AppsServerProxy.mcpArguments nil→[:]、decodeArguments を .value/.invalid 化(空→{}・壊れ JSON は
    ツール未実行で role:tool エラー)、診断ログ撤去。
  - 論点2: 空 tool-result が prev=[] を確立 → 自己 refresh で全件「同期(追加)」誤演出。
    F2: isError:true 結果ではカードを起こさない(r.result["isError"].boolValue)。
    「+ ボタンで同期」は事実無根(caldav FAB はローカルドラフトのみ・todos-entry.ts:3301-3310)。
  - 論点3: 観測はアプリ責務(caldav 要件でない)。TraceSink 1 seam を T6 と同時(F3・未実装)。
    Langfuse/OTel は LLM プロキシ段階でサーバー側。UI ツール結果フル JSON はコスト実測まで維持。
- 実機再検証(F1/F2 適用): 「todoを見せて」1回成功・カード初回から実データ・追加演出なし = 判断ゲート通過。
  caldav 実状態3件(追加へ1/テスト/test・新規はテスト操作中に削除・追加へ1 の優先度/繰り返しも
  テスト中の write で変化)とアプリ表示が一致 = write 往復も実働。swift test 76 件 green。
- 残: カード内 complete の write 往復の明示目視 / モデルが list-calendars を先呼ぶ癖(system prompt 誘導)。

## 2026-07-16 ツールステップ展開表示 + テスト teardown crash 修正

- 機能(implementer 委譲): ツール呼び出しステップをタップで展開し「リクエスト(引数)/
  レスポンス(結果)」を pretty JSON・等幅・最大高さ+内部スクロール・コピー可で表示。
  ToolCallStep に resultJSON 追加(argumentsJSON と対・永続化 DTO 兼用 = T6 履歴/観測に乗る)。
  ChatViewModel が結果を step に転記。ChatBodyView の toolStepRow を ToolStepRow(private struct・
  @State 開閉)に切り出し。
- **回帰の発見と修正(main)**: subagent が「flaky」と流した swift test の signal 11 は決定的回帰だった。
  切り分け: b597f6c は 5/5 安定 → ToolCallStep に resultJSON を足すと ChatViewModelTests(@MainActor
  @Observable な ChatViewModel を回す suite)の**並列 teardown で SIGSEGV**(Swift 6.3/macOS 26 の
  ツールチェーン脆弱性・テスト自体は全 pass)。field 有無/Kernel 単独/suite 単位で crash が入れ替わる
  ことを確認。→ ChatViewModelTests を @Suite(.serialized) 化(理由コメント付き)。swift test 76 件 4/4 安定回復。
- 実機で展開 UI 動作確認。リクエスト {} は F1 修正後の正常状態(絞り込み不要な list-todos)。

## 2026-07-16 P3 T6 前半: 観測(TraceSink)+ 履歴永続化(ChatStore write)

- 目的: 「ユーザーのチャット + tool calling を後から取得・分析できる」状態にする(ユーザー要望・design 03 §3)。
- F3 TraceSink(implementer 委譲): Kernel/Tracing/ChatTraceEvent(turnStarted/llmCompleted/
  toolCallStarted/toolCallFinished/turnSettled・Codable)+ Services/Chat/TraceSink protocol +
  OSLogTraceSink(category chat-trace・1行整形・引数本体はプライバシーで出さない)。ChatViewModel の
  5注入点で fire-and-forget emit。durationMs は実測(Date)。壊れ JSON の tool_call は emit しない。
- 永続化(design 02 §5): Services/Chat/ChatStore(1 ChatSession=1 JSON + index.json・baseDirectory 注入で
  テスト可能・atomic 書き込み・NSLock 直列化・破損 index はログして空扱い)。save/loadIndex(updatedAt 降順)/
  load/delete。ChatSession に model 追加、ChatSessionSummary(Kernel)追加。
- 配線: ChatViewModel に traceSink/sessionId/serverURL/onTurnSettled(全 default nil で後方互換)+ currentSession
  (title=最初の user 発話 40字)。ChatHomeViewModel が接続時に sessionId 発番 + OSLogTraceSink 注入、
  onTurnSettled で store.save(失敗はログして続行)。保存先は Application Support/chats/(取れなければ temp)。
- テスト: ChatStore round-trip/降順/delete/破損耐性、ChatViewModel の trace 順序(SpyTraceSink)、
  ChatTraceEvent Codable。新スイートは @Suite(.serialized)(teardown crash 回避)。swift test 93 件 green・3x 安定。
- T6 後半(次): サイドバー UI + 過去セッション復元 + カードスナップショット。

## 2026-07-16 P3 T6 後半 B/C: 履歴サイドバー + 復元ビュー

- D/E(前コミット 1dc4239): スナップショット取得+書き戻し・静的カードビュー。
- B/C(artisan 委譲・中断→再開・main レビュー):
  - ChatHistorySidebar: loadIndex を日付グループ(今日/昨日/今週/それ以前)+ 検索(title/preview 部分一致)
    + 新規チャット + 行スワイプ削除。引き出しは ZStack + 暗幕 + move(.leading) の overlay drawer
    (モック準拠・.sheet でなく)。空状態メッセージ。
  - ChatHomeView: ☰(leading)/ compose(trailing)追加。drawer 提示・履歴ルーティング・load 失敗アラート。
  - ChatHomeViewModel: DisplayMode(.live / .viewingHistory(ChatSession))を state と直交で新設
    (接続 connecting/failed でも履歴は読める)。openHistory/returnToLive/newChat/clearHistoryLoadError。
    新規チャットは ConnectionContext(proxy/toolDefs/uiResourceURIs/serverURL を保持)を再利用して
    OAuth 再対話ゼロで新 sessionId の空 ChatViewModel を組む。makeChatViewModel 抽出。chatStore 公開。
  - HistoryDetailView: 読み取り専用(composer 無し・proxy/ChatViewModel/LLM に触れない=副作用ゼロ)。
    ToolStepRow 再利用で req/res 展開。カードは snapshotHTML→StaticCardView / 無ければプレースホルダ
    (structuredContent 折りたたみ閲覧付き)。
- 判断: 履歴 continue 非対応(設計 §5「再実行しない」)。日付グループは月ラベルでなく 4段(可逆)。
- make app BUILD SUCCEEDED / swift test 93 件 green(複数回・teardown crash 無し)。
- 実機目視(サイドバー操作 + スナップショット再訪)は継続。軽微: サイドバー削除失敗ログが print。

## 2026-07-16 サイドバー redesign(Claude iOS 準拠)

- ユーザーが「素の List でダサい」→ fable に redesign 依頼。初版(inset カード案)を出したが、
  ユーザーが実機 Claude iOS のスクショ3枚を参考提示 → 手本に寄せて修正(docs/modeling/ui-mockups/sidebar-v2.html)。
  手本の要点: edge-to-edge + ヘアライン(inset カードでない)・行=太字タイトル+相対時刻・preview 非表示・
  下部フローティング黒ピル新規チャット・アクティブ角丸ピル塗り・日付グループ見出し廃止・温かい paper。
- 実装(implementer 委譲): ChatHistorySidebar 全面書き換え + ChatHomeView の drawer chrome 調整。
  - 相対時刻 RelativeDateTimeFormatter(.named)。preview は表示から外すが検索対象には残す。
  - サーバー chip は Set(serverShortName).count>1 の一覧単位判定(単一サーバー時は非表示・汎用ホスト布石)。
  - 下部フローティング FAB(overlay・ダークで黒→白反転)。アクティブ行は listRowBackground の角丸ピル。
  - Asset catalog 無しのため SidebarPalette(動的 Color・sidebar-v2 の Hex 写経)で light/dark 定義。
  - 削除失敗ログを print→Logger(category sidebar)。コールバック契約・store 直読み・削除冪等は不変。
  - drawer: 幅 min(width*0.82,320)・右端のみ角丸20・影・暗幕0.3・左スワイプ閉じ・☰ トグル。
- ☰ を toggle 化(ユーザー指摘・再押しで畳む)。
- 将来: サイドバーのハブ化(上部に接続先サーバー切替/追加・アカウント・設定)を next-directions P4(c) に記録。
- make app BUILD SUCCEEDED / swift test 93 件 green。実機ビジュアル最終確認は継続。

## 2026-07-16 UI ポリッシュ(サイドバー) + 掃除

- サイドバー redesign(fable モック sidebar-v2.html 合意)→ 手本 Claude iOS 準拠に全面刷新。
  - 「コンテンツ右スライド式」: 下層=サイドバー、上層=角丸カードのメインが右へ退く(手本 image14/15)。
    ZStack ごと .ignoresSafeArea() でカードを物理端まで bleed(退いても縦エッジのみ・上下は出ない)、
    サイドバー内容だけ safe area inset で寄せる。navbar は NavigationStack が自前で safe area 確保。
  - 横ドラッグで指追従。@GestureState は終了時 0 リセットで committed 反映との隙間 → ちらつき →
    @State(dragTranslation)にして snap と reset を同一 withAnimation 内で(隙間ゼロ)。
  - snap 閾値: 「全開幅 40% 位置」の単一閾値だと閉じるのに 60% 動かす必要 → 現在状態基準 22%+速度
    (predictedEndTranslation-translation>100pt)の対称・軽量判定に。
  - 暗幕: progress(0..1)駆動で完全展開まで薄暗く・開ききると 0(手本・opacity 0 で hit-test も外れる)。
  - ハプティクス: .sensoryFeedback(.impact(.medium), trigger: showingSidebar)(iOS 17+ 推奨・snap 時発火)。
  - ベスプラ調査: useyourloaf/hackingwithswift(sensoryFeedback)・itwenty(fraction 駆動・
    predictedEndTranslation スナップ・エッジ閾値)。
- インラインカード: 600 キャップで todos 9件が切れて + ボタン到達不能 → **内容に応じて高さ追従**
  (キャップ 4000 安全網・ネスト内スクロールは不採用=チャット全体でスクロール)。
- キーボード出っぱなし修正: @FocusState + scrollDismissesKeyboard(.interactively) + タップ外し
  (simultaneousGesture TapGesture)+ 送信時 dismiss。
- model chip 2段化(接続先+モデル名・タップで設定)。デバッグフック MCPHOST_SIDEBAR_OPEN 追加
  (agent が open 状態をスクショ検証するため)。実機(iPhone 12 mini)で全確認。
- 次: T7 コスト表示(litellm pricing JSON から取得・未知は "—")。

## 2026-07-16 P3 T7: コスト表示(litellm pricing)

- 実装(implementer 委譲): Kernel/Pricing/ModelPrice(純データ)+ estimatedCostUSD(純計算)。
  Services/Chat/PricingStore(@MainActor・litellm model_prices_and_context_window.json を fetch →
  [modelId:ModelPrice] にパース(sample_spec 除外・input/output 両数値のみ)→ Application Support/
  pricing/ にディスクキャッシュ(TTL 7日)・fetch 失敗は stale cache fallback・失敗はログ(category pricing)。
  parse は static でネット非依存=フィクスチャでテスト可)。
- ChatViewModel に modelPrice(後入れ・既定 nil)+ lastCostUSD/cumulativeCostUSD(usage×price・
  どちらか nil なら nil)。ChatHomeViewModel が init で fire-and-forget load・接続後/新規チャット後に
  chatVM.modelPrice を設定(接続をブロックしない)。
- UI costHint: トークンは常に表示、既知時のみ「≈ $%.4f」を追記。未知/未ロードは $ を省略
  (設計 §6「嘘の金額を出さない」・"—" の埋め草も出さない解釈)。gpt-5.4-mini は litellm 収録済みで実額が出る。
- テスト: Kernel(コスト計算・round-trip)、Services(litellm 抜粋フィクスチャのパース・cache round-trip・
  未知→nil・sample_spec/欠損除外)、ChatViewModel(@Suite(.serialized)・modelPrice 有無でコスト計算)。
  swift test 103 件 green(3x 安定)。make app BUILD SUCCEEDED。
- これで P3(T1〜T7)完了。実チャットでの ≈$ 表示目視は実機/シミュレータで確認。

## 2026-07-17(続き・場所/会議の問題提起 → 設計 05 正典化)

- ユーザー問題提起「vevent/vtodo どちらでも場所の入力体験が弱い」から4層の発見:
  意味モデル(場所/会議/URL の3スロット)・read 未対応・入力体験・ホスト権限の天井。
- 本番 D1 の生 ICS を直接採取して decode(自宅到着 proximity VALARM・岐阜大学
  structured-location・paiza 招待の URL=message: + DESCRIPTION ビデオ通話ブロック)。
  「CONFERENCE 新設が要る」見積りを撤回(Apple 自身が規約+走査で実現)。
- サンドボックス制約の切り分け: カード全遮断(ContentRuleList)は事実だが、
  geocode は Worker 側で可・地図確認は (a)静的サムネ/(b)宣言型網許可(H-a)の2案で留保。
  「サンドボックス緩和=工数大」も撤回(数行。難しいのは権限モデルの設計判断)。
- inline モデル再設計の裁定: プレビュー化(すべて表示廃止)・完了残骸 lifecycle+5秒退場・
  削除ゴースト廃止・vevent 作成は fullscreen 詳細フォーム・vtodo は既存 quick-add 維持。
- docs/design/05-location-and-conference.md 新設(D1 完了)。タスク C0〜C8 / H-a,b 登録。
- 実装面: fullscreen zoom transition(host e1e0a2a)・fullscreen 固定 FAB(caldav bc5ebd1)。

## 2026-07-17(続き2・3レーン並列実装ラウンド)

- 並列レーン構成(ファイル競合で分割): C0=caldav ui/、C1=caldav usecases/(ui 触るな指示)、
  UX #5/#6=host。C2 は C0 と同 entry ファイルのため C0 着地後に直列起動。
- C0(caldav 9756fe8): プレビュー化(INLINE_PREVIEW_MAX=5・computeInlineFit は安全クランプに
  役割変更・履歴積層)、完了残骸5秒退場(exitTimers/retiredDoneIds 冪等)、削除ゴースト廃止。
- C1(caldav 8c51ca5): structured-location.ts 新設(semantics 層・degrade 方針)。server.ts
  無変更(スプレッド透過)。実データ3種フィクスチャ。
- C2(caldav 9e9b751): location-view.ts(描画判断の純関数)。agenda meta 3スロット統一形・
  todos 到着時バッジ。inline は会議優先の主要1つ。
- host(129b725): prefersBorder(既定 true=退行ゼロ)+ ダークモード(HostThemeBuilder・
  最小6キー・notifyThemeChanged 部分通知・overrideUserInterfaceStyle)。
- C0 実装途中に API 証明書エラーで artisan が落ちた → SendMessage 再開で無傷続行(作業
  ツリーはクリーンのまま)。C0 コミット時は C1 走行中ファイルを除外して選択ステージ。

## 2026-07-22(シミュレータ E2E: reparent「右上ズレ」検証)

- Claude Code の iOS Simulator MCP ツールで初のシミュレータ自動検証ラウンド。
  iPhone 17 / iOS 26.4。`make app` ではなく MCP の build → launch を使用(BUILD SUCCEEDED 47s)。
- 通常起動では caldav が needsAuth(「タップで認証」)で、同意画面にパスワード欄が出る。
  資格情報入力はエージェント側で行わない方針のため、対話 OAuth を要する項目は保留。
  → 代わりに **MCP 接続を要さない `MCPHOST_SPIKE=reparent` ハーネス**へ切り替えて先行検証。
- 検証結果(右上ズレ解消 ✅): inline `{tick:665,manual:3,input:""}` → 入力を dirty 化 →
  昇格時 **sheet 直前/直後がともに tick:1980**(リロード無し=同一 WebView の reparent 成立)→
  sheet 内 +1 → dismiss 後 `{tick:2800,manual:4,input:"Dirty-state-42"}`。
  レイアウトのズレ・はみ出しは目視でも無し。unified log(subsystem dev.gigun.mcphost・
  category reparent-spike)の PROBE 行で同値を裏取り。
- 手順ハマり2点(次回のため): ①スクリーンショットは 918px 幅で返るが tap/swipe は 402pt 空間 —
  約 2.284 で割って渡す。②`simctl launch --setenv` は当環境で「Invalid device」になる。
  環境変数は `SIMCTL_CHILD_<NAME>=value xcrun simctl launch --terminate-running-process <udid> <bundleid>`。
- 副次観測: 既定 LLM が gpt-5.4-mini(OpenAI 互換)で CLAUDE.md の「Anthropic API」と不一致。
  (当初「next-directions.md:58 の参照先『2026-07-22 タスク棚卸し』節が未執筆」と記録したが
  **誤り** — 393 行に実在した。grep の絞り込み不足による誤認。撤回する)
  Swift 6 でエラー化する警告が ChatViewModel(diagLogger)・InlineCardView(captured var self)に残存。

## 2026-07-22(続き・棚卸し「未検証」消化 + URL バリデーション実バグ修正)

- デプロイ状態の確定: Cloudflare Workers Builds API(MCP プラグイン経由)で caldav worker を照会。
  最新ビルド dd56d30(07:10Z・success)= ローカル HEAD 一致、直近8件すべて success。
  → next-directions.md の「未デプロイ: bc5ebd1〜9e9b751」は解消済みとして訂正。
  ab5b153(openLink 正規経路化)・fa84ceb(⊕ 常時昇格)・dd56d30(コレクション選択)も配信済み。
- `MCPHOST_SPIKE=todos` で caldav 本番の実データ描画に成功(Keychain トークン生存・無言接続)。
  合格: コレクション選択ドロップダウン(クリップ無し)/reading list 切替+コレクション色/
  action-row 統合(浮遊 FAB 無し・内部スクロール消滅)/⊕ ドラフト行 + プログラム的 focus で
  キーボード表示(スウィズル af98e59 の実証)/ scrollIntoView。
  スパイク画面は昇格先を持たないため ⊕ は inline フォールバック = 設計どおり。
- M1/M2: caldav + tdr-concierge の2サーバー同時「接続済み」。ServerDetailView のツール一覧が機能。
  tdr-concierge は OAuth 不要で繋がるので、認証を挟まない2台目検証の相方に使える。
- **実バグ発見→修正**: サーバー追加フォームの URL 欄はプリフィル "https://" があり、
  フル URL を貼ると "https://http://…" になる。`URL(string:)` はこれを scheme=https/host=http と
  解釈するため旧検証(scheme=="https" && host != nil)を通過し、壊れたエントリが保存できた
  (接続時 NSURLErrorDomain -1003)。Kernel/MCPEndpoint/MCPEndpointPolicy.swift に純関数として
  切り出し、二重スキームは URL パース前に文字列段階で弾く(パース後だと理由が的外れになる)。
  host はドット必須 + localhost 例外。文言は Features 側(ServerFormSheet.message(for:))。
  swift-testing 11 ケース・make check 172 green・シミュレータで再現手順を踏んで実地確認済み。
- 保留(LLM API キー未設定のため): ⊕ の常時 fullscreen 昇格 / 両サーバーのツール混在 /
  open-link / C3・C4 フォーム(agenda カードが要る)。キー入力はエージェント側では行わない。

## 2026-07-22(続き2・検証ノウハウの skill 化 + rules の不整合修正)

- **`.claude/rules/comments.md` が一度もロードされていなかった**: frontmatter の paths が
  caldav(TypeScript)から移植したままの `src/** test/** proxy/** scripts/** migrations/**` で、
  本リポジトリの Swift 構成に一致しない。CLAUDE.md は「コード編集時に自動ロード」と
  書いていたのに実際は無効だった。`Sources/** Tests/** Package.swift project.yml` へ修正。
  → コメント規律が効いていなかった理由が判明(これまで守られていたのは都度指示していたため)。
- 検証ノウハウを **skill `.claude/skills/ios-e2e-verify/SKILL.md`** に切り出し。
  常時ロードの CLAUDE.md ではなく skill にしたのは、検証の話題のときだけ読めば十分でトークンが
  もったいないため(claude-code-guide の判断基準: 常時必要=CLAUDE.md / ファイル種別限定=
  .claude/rules の paths / 作業限定の手順書=skill / 起動時に計算して注入=SessionStart フック)。
  CLAUDE.md からは1箇所だけ参照を張って発見性を確保。
- skill に載せた事実(いずれも今日実地で踏んだもの):
  - `simctl launch --setenv` は当環境で不可 → `SIMCTL_CHILD_<NAME>=value` を使う。
  - **`MCPHOST_LLM_KEY` の env 経路で API キーを貼り付けずに渡せる**(env > Keychain > 空)。
    ダミーキーで起動して設定画面に値が入ることを実証。env は init でしか読まないので毎起動必要。
    どうしてもペーストしたい場合は `echo -n <値> | xcrun simctl pbcopy <udid>`(履歴に残る点に注意)。
  - スクショは 918px 幅・タップは 402pt 空間(約 2.284 で割る)。
  - iOS control には key/double_click/triple_click が無く、**テキスト削除ができない**。
    既存値を消す編集は「削除して作り直す」が現実解。
  - ソフトキーボードが画面に出なくても focus は当たっており `text` は通る
    (これを誤認して遠回りした。ユーザーからの指摘で判明)。
  - スパイクの使い分け: reparent=MCP 接続不要 / todos=要トークン / transport=不要。
    スパイク画面は FullscreenCoordinator を持たないので ⊕ の inline フォールバックは正常。

## 2026-07-22(続き3・検証ループの自動化 + ヘッダー接続表示の再設計)

- **`make run` を追加**: `.env`(元から .gitignore 済み)に MCPHOST_LLM_KEY を1度書けば、
  ビルド → install → **鍵入りで launch** まで一発。BYOK キーを毎回シミュレータの設定画面へ
  手で貼る苦痛(かつエージェントは資格情報をフィールドに入力しない運用)を仕組みで解消した。
  実装の肝: **値が空の変数は渡さない**。LLMSettingsStore は `env[...] ?? Keychain ?? ""` で
  **空文字も「値あり」と見なす**ため、空を渡すと Keychain 保存済みの鍵が無視される。
  鍵はコマンドライン引数でなく export で渡す(ps で覗けるため)。
  `.envrc`(direnv・`dotenv_if_exists .env`)も追加したが、Makefile 側は direnv に依存しない
  — 非対話シェル(エージェントの Bash・CI)では direnv フックが走らないことがあるため。
  `.envrc` は秘密を持たないのでコミット対象、`.direnv/` は除外。
- xcode-mcp プラグイン(`xcrun mcpbridge`)は settings.json で有効だが、当セッションでは
  `mcp__xcode__*` が現れず未使用。実際に使ったのは Claude Code 組み込みの iOS Simulator MCP
  (build / control)+ 素の xcodebuild・simctl(MCP の launch には env を渡す口が無いため)。
- **ヘッダー「2/2 接続」を再設計**(ユーザー指摘「意味不明」)。モックで4案を提示 → ユーザー判断は
  「基本は消していい・名前を並べるのはスペース的に無理」。他製品調査(claude.ai/ChatGPT/
  Claude Desktop/VS Code)で**4製品とも接続状態をヘッダーに出さない**ことを確認し、
  Apple HIG(タイトルは現在地の説明・冗長なら空でよい)と WCAG 1.4.1(色だけの状態表示は違反)
  で裏取り。→ 正常時は消してモデル名のみ、異常時だけアイコン+テキストで「n 件 未認証」。
  詳細と出典は next-directions.md「接続状態をどこに出すか」節。
  将来課題として「入力欄側のツールピッカー」を起票(業界の定石だが本アプリは未実装)。

## 2026-07-22(続き4・ヘッダー実装 + LLM tool-use を実地で通した)

- ヘッダー再設計を実装(implementer 着手 → ユーザー停止 → main が仕上げ)。ユーザー FB
  「スペース的にアイコンとテキストは厳しい」を受け、**警告を独立行にせずモデル名と同じ行の
  アイコン1つに畳んだ**(横幅増分 ~14pt)。視覚テキスト(「n 件 未認証」)は撤去し、
  件数・種別は accessibilityLabel に集約(WCAG 1.4.1 が禁じるのは「色**だけ**」で、
  警告三角は色を落としても形状で平時と区別できるため、テキストを省いても適合する)。
  AttentionBanner.text はボツ案としてコメントに経緯を残して削除。
  実機確認: 平時 `gpt-5.4-mini ⌄` / caldav 要認証時 `⚠ gpt-5.4-mini ⌄`。
  メニューを開くと `! caldav(要認証・タップ)` `✓ tdr-concierge` で内訳が読める。
- **`make gen` を xcodegen 非依存に**: この Mac の PATH に xcodegen が無く(nix/mise/brew の
  どこにも無い)、gen に依存する app/device/run が全て落ちていた。既存の .xcodeproj があれば
  警告して続行、両方無いときだけ導入方法を添えて落とす形に。
- **`.env` の実キーは `OPENAI_API_KEY` だった**(MCPHOST_LLM_KEY ではない)。Makefile に
  `: "$${MCPHOST_LLM_KEY:=$$OPENAI_API_KEY}"` のフォールバックを追加 → `make run` だけで
  鍵入り起動が成立(設定画面のキー欄に値が入ることを確認)。
- **LLM tool-use ループを実地で通した ✅**(P3 以来ひさびさの実 E2E):
  発話 → `✓ [T] tdr-concierge · park_waits` の ToolStepRow → **park_waits のカードが描画** →
  「全アトラクションが休止中(2026/07/22 21:40 時点)」と要約 → コスト表示
  (このターン ≈4,280 tok ≈$0.0036 / 累計 5,107 tok)。
  **ツール名前空間化の逆ルーティングが実動作で確認できた**(park_waits が tdr-concierge へ)。
  tdr-concierge も MCP Apps 対応(カードを返す)と判明 — caldav 以外での初のカード描画。
- 新たな検証制約(skill に追記): **`text` は printable ASCII のみ**で日本語は送れず、
  さらにキーボードが日本語入力モードだと ASCII すらローマ字変換される(「うぁたれてぇ…」)。
  変換候補タップで確定できるがスペースが落ちる。検証発話は最初から英語で組むのが速い。

## 2026-07-22(続き5・開発環境の宣言的用意を調査 → project flake は撤回)

- ユーザー要望「xcodegen を宣言的に用意したい。nix なら CI の選択肢も変わるのか、ベスプラ調査を」。
  一度 flake.nix(devShell に xcodegen/swiftformat/swiftlint)+ .envrc の `use flake` +
  Makefile を `direnv exec` 委譲、という構成を作ったが、**調査と実測で撤回**。
- 撤回の決め手(実測): `direnv exec .` の中で DEVELOPER_DIR/SDKROOT が nix の apple-sdk-14.4 を
  指し、xcrun が 2019 年の xcbuild 製に差し替わっていた。xcodebuild は /usr/bin のままなので
  「Apple の xcodebuild が nix の macOS SDK を見る」壊れた組み合わせ(nixpkgs#355486)。
  coder-desktop-macos / ghostty は mkShellNoCC + unset + PATH 掃除で回避しているが、
  それは devShell に入った上で nix のツールチェインを無効化する構成で、得られるのはツール3つ。
  → ユーザー環境(dotfiles の nix)に入れる方が単純で事故らない、と判断(ユーザー選択も A)。
- 撤回後 `make run` で Apple の iPhoneSimulator26.4.sdk が使われることを確認 ✅。
- 調査で確定: **iOS では `nix build`/`nix flake check` でアプリをビルドできない**
  (Xcode はライセンス上パッケージ化不能・derivation 内はネットワーク無効で SwiftPM が解決不可)。
  よって nix で make を置き換える道は無く、「nix はツール供給・make はタスクランナー」が定説。
  CI 定番は nix-quick-install-action(macOS 約5秒)+ **store キャッシュ無し** + setup-xcode。
- flake.nix を git add していないと nix から見えない件は nix#7107 の open issue。まさに踏んだ。
- Makefile の変更: direnv 依存を撤去し素の PATH へ。**`make check` の「未インストールなので
  skipping」を廃止して落とすように**した — これまで lint が一度も走っていないのに緑だった。
  `make gen` は xcodegen 不在時、**project.yml と .xcodeproj のタイムスタンプを比較**し、
  project.yml が新しければ中断する(古い定義で気づかずビルドするのを防ぐ)。
  `make doctor` を新設(3ツールと鍵の有無を一覧)。秘密だけは direnv 経由で読む。
- 残: dotfiles の nix に xcodegen/swiftformat/swiftlint を追加(ユーザー作業)。
  いずれも nixpkgs にあり aarch64-darwin 対応を確認済み。
  > **2026-07-22 追記:** dotfiles(`nix/modules/home/packages.nix` の darwin ブロック)に
  > xcodegen/swiftformat/swiftlint は追加済みを確認。同ブロックに **`idb-companion` も追記**した(下記)。

## 2026-07-22(続き6・Desktop の iOS Simulator MCP をリバース → 汎用 skill 化)

- 発端: 2026-07-21 に Claude Code **Desktop** が「iOS Simulator ペイン」を追加(公式 docs
  `code.claude.com/docs/en/desktop-ios-simulator`)。ツール名前空間が `mcp__Claude_Code_iOS_Simulator__*`
  と判明していたので「CLI でも同じことができるのか/サードパーティ要るのか」を調査。
- **Desktop 実装をリバース**(`/Applications/Claude.app` の `app.asar` を @electron/asar で展開・
  `.vite/build/index.chunk-*.js` を解析)。判明した実体:
  - `simulatorServerDefinition`(サーバー名 `"Claude Code iOS Simulator"`)= **アプリ内蔵 MCP**。
    ツールは `control`(alwaysLoad)+ `build`(dynamic)。
  - `isEnabled: e => e.sessionType === "ccd" && !e.isSSH && …` で **ccd(=Desktop)専用ゲート**。
    stdio/http で外から刺せる独立サーバーではなく **main プロセス内実装** → CLI から再利用は不可。
  - 裏の駆動は **`xcrun simctl`(boot/launch/openurl/screenshot)+ native "sidecar"(live streaming
    ペイン用の binary stdin/stdout プロトコル)+ `idb`(tap/swipe/text/button ← `isIdbAvailable()`
    ガード)**。再現不能な私的フレームワークは無い。
- **結論**: リバースはコードとしては行き止まり(ccd ゲート・in-process)。だが**抽出したツール
  description/inputSchema/エラー文言はコンテキストエンジニアリングの写経元として有用**。特に:
  - **座標は device points(左上原点)で統一・`launch` が point 寸法を返す**。実行時も毎回
    `Coordinate space for screenshot/tap/swipe: {W}x{H} pixels` をスクショと一緒に明示 → 「見ている
    座標空間」と「打つ座標空間」の食い違いを消す設計。過去に苦しんだ **918px/402pt ズレの答え**。
  - attach-first / screenshot・入力は headless / build・unit-test だけなら panel 開かない。
  - エッジ 4pt 以内始点の swipe は OS ジェスチャ(左=戻る・上=通知・下=ホーム・右=CC)。
  - tap `duration>0.5` で長押し・swipe 既定 0.3s・ボタンは HOME/LOCK/SIRI/SIDE_BUTTON/APPLE_PAY。
  - エラーは「次の一手を添える」(`No booted simulator named 'X'. Boot it with: xcrun simctl boot X`)。
- **成果物**: 個人マーケットプレイス `gigun-dev/claude-code` の **`ios-skills` プラグインに新スキル
  `ios-simulator` を追加**(汎用・全プロジェクトから再利用可)。scope は操作系のみ(build は
  `ios-device-build`/各プロジェクトのビルドツールに委譲)。
  - `SKILL.md`: 上記知見の写経 + Desktop control → CLI(simctl+idb)対応表 + 座標規律。
  - `scripts/sim-shot.sh`: スクショ + pixel/point/scale を毎回明示。**実 simulator(Booted iPhone 17)で
    検証済み ✅** — `1206x2622 pixels`(= 402pt × scale 3)で座標理論が実測一致。
  - `scripts/sim-tap.py`: `idb ui describe-all` のラベル一致要素の**中心(points)をタップ** →
    スケール変換不要で座標ズレを根絶。uv の PEP 723 inline(事前 pip 不要・stdlib のみ)。
- **座標系の確定事実**: スクショ=pixels / `idb ui tap`=points / `describe-all`=points。
  差は端末スケール(Retina 2〜3倍)。ラベル指定タップ(centerX/centerY)が最短の解。
- idb の 2 コンポーネント: `idb-companion`(nixpkgs 1.1.8・aarch64-darwin)を **dotfiles の nix に追記済み**。
  `fb-idb`(Python CLI `idb`)は nixpkgs に無く **`uv tool install fb-idb`**(ユーザー作業)。
- 残(ユーザー作業 → 後で私が E2E): ① dotfiles を darwin-rebuild で反映 ② `uv tool install fb-idb`
  → `idb connect` ③ その後 `sim-tap.py`・`sim-shot.sh` の scale 算出まで idb 経路を実機検証。
  ※ idb-companion 1.1.8 は Xcode の Simulator ランタイムと相性問題が出たら Homebrew 版に逃がす。

## 2026-07-22(深夜): Claude Code / Codex共有ハーネスとcontext注入の棚卸し

- `AGENTS.md→CLAUDE.md`、`ios-e2e-verify`、comments rule、SessionStart scriptをsymlinkで共有し、
  Codex固有adapterにはhook lifecycleと`xcrun mcpbridge`だけを置いた。validatorは全項目green。
- `ios-simulator`は全project共通のSimulator CLI操作、`ios-e2e-verify`はMCPHost固有E2Eなので両方維持。
- Claude project memory/session JSONLは同期せず、恒久情報はrepo instructions/docs/skillsへ昇格する方針にした。
- `session-head-end`が340行目まで後退し、hook出力が約36KBになっていた。履歴を消さず、先頭28行・
  2.7KBの最新サマリでmarkerを閉じ、詳細は後段をオンデマンド参照する構成へ修正。
- `make check`: buildと全testはgreen。新たに厳格化されたSwiftFormatが既存67/81 filesの未整形を
  検出して失敗したため、機能退行とは分離してformat debtとして扱う。dirty本体の
  `MCPEndpointPolicyTests`は11/11 greenを再確認した。

## 2026-07-23: dirty全体をiPhone 12 miniへ実機build/install/launch

- `ios-device-build` skillをCodex plugin実体から実行。skill設定の端末名
  `iPhone 12 mini morita` は現在のCoreDevice表示名`iPhone`と一致しなかったため、接続中の
  iPhoneを明示指定した。
- Apple Development署名 + Team provisioningで`BUILD SUCCEEDED`。生成された
  `Debug-iphoneos/MCPHost.app`をinstallし、bundle ID `dev.gigun.mcphost`でlaunch成功。
  起動後も`devicectl device info processes`でMCPHost executableとPIDを確認し、即時crashしていない。
- CoreDeviceは各command冒頭で`No provider was found`警告を出すが、tunnel取得・Developer Disk Image・
  install・launch・process照会はすべて成功しており、この実行の阻害要因ではなかった。
- commit前監査でsecret候補・broken symlinkは無し。一方lintはbaseline未整備:
  SwiftFormat 67/81 files、SwiftLintはSources/Testsだけでも290 findings/42 files。さらに現Makefileの
  `swiftlint`は`.build`配下の依存まで走査する。機能変更とlint基盤整備を同じcommitに混ぜるかは要判断。

## 2026-07-23: dirty完了監査 — lint基盤とSimulator対象を確定

- 上記の「baseline未整備」をこのdirtyの未完了タスクとして巻き取り、`.swiftlint.yml`と
  `.swiftlint-baseline.json`を追加。既存290件は隠して忘れるのではなく既知負債として固定し、
  今後増えた違反だけを`--strict`で失敗させる。baseline解消は触るコードから段階的に行う。
- SwiftFormat既定値の全面適用は、import横の経緯説明など本repoのコメント規律と衝突するため不採用。
  空白・重複import・末尾改行など意味を変えない字句ルールだけを`.swiftformat`へ明記し、既存違反
  6ファイル7箇所を機械整形した。
- 過去ログの「Makefile側はdirenvに依存しない」は、正確には**ビルドtoolchain/PATHをdirenvに
  委譲しない**という意味。`make run`は秘密を`.env`から安全に渡す用途に限って`direnv exec`を使う。
- `make run`がinstall/launch先に曖昧な`booted`を使っていたため、指定したSimulator名からUDIDを
  一度解決し、boot/install/launchの全工程を同じUDIDへ固定した。複数Simulator起動時の誤配送を防ぐ。
- server設定編集後もready接続が旧name/URL/slugを保持する問題を同じdirtyの未完了として修正。
  `MCPConnectionIdentity`で登録内容との差を判定し、ready中だけでなくconnecting中の編集もcancelして
  再接続する。rename→旧名と同名serverを追加したときのslug衝突・tool誤配送を含む5 testsを追加。
  URL変更時の旧Keychain tokenは、同URLを共有する別登録を壊さないため意図的に保持する。
- 最終`make check`はgreen: Swift build、177 tests / 18 suites、SwiftFormat 0/83、
  SwiftLint 0 violations / 82 files。Codex migration validatorもconfig、xcode MCP command、project skill、
  root/Sources/Tests instructionsの全項目green。SessionStart注入は2,856 bytesに収まる。

## 2026-07-23: remote MCP追加フォームの初期状態と検証表示を整理

- 新規serverのname/URLを空で開始するよう変更。URL欄の`https://`プリフィルはフルURLのペーストを
  邪魔し、未操作なのに不正状態を作るため廃止した。
- `caldav`や`https://example.com/mcp`のような実データ風placeholderも廃止し、フィールドの役割だけを
  示す`表示名` / `URL`へ変更。正常時の説明footerは表示しない。
- URLエラーは、非空の入力を終えてURL fieldからfocusを外した後だけ表示する。再編集のfocus中は隠し、
  入力前・入力途中にフォームから叱られる状態を避ける。保存は従来どおり表示名と有効なhttps URLが
  揃うまで無効で、`MCPEndpointPolicy`の二重スキーム等の防御は維持する。
- iPhone 17 Simulatorへ`make run`でinstall/launchし実画面を確認。新規フォームは空の`表示名` / `URL`
  だけで、初期エラー・正常footerとも無し、保存は無効。不正な非空値を入力して別欄へ移ると赤字が現れ、
  URL欄へ再focusすると消えることをアクセシビリティツリーとスクリーンショットで裏取りした。

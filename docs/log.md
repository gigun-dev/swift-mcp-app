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

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

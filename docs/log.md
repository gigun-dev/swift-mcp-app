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

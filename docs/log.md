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

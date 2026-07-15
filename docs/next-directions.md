# 次セッションの方向性(2026-07-15 第2版: コア価値を「iOS 汎用 MCP Apps ホスト」に転換)

> **位置づけ**: 恒久ドキュメント(セッション引き継ぎの正典)。セッション開始時にまず読む。
> **更新ルール**: 計画は消さない。完了は打ち消し線 + ✅、状況変化は該当箇所の直下に
> `> **YYYY-MM-DD 更新:** ...` の引用ブロックを積層する。大きな節目で全体を棚卸しする。
> 時系列の生記録は docs/log.md に追記(追記専用アーカイブ)。運用は caldav 側と同一。

**現在地(2026-07-15)**: コア価値を初版の「契約のネイティブ SwiftUI 描画(路線A)」から
**「iOS 汎用 MCP Apps ホスト(路線B)」に転換**(ユーザー確定)。理由: caldav 側 E-2 が
本番検証込みでクローズし、todos v3 / agenda の検証済みインタラクティブ UI(ext-apps 製・
計約7,500行)がサーバー側に存在する今、ネイティブ再描画は二重実装になる。Swift 側の
最大の付加価値は「モバイルで MCP Apps を動かすホスト基盤」(≒ claude.ai モバイルの自作版。
iOS ネイティブの汎用 MCP Apps ホストは前例がほぼ無い)。**コードは未着手**。
~~既存の Swift/iOS MCP Apps ホスト事例と ext-apps ブリッジプロトコルのリサーチを実施中~~ ✅
→ **リサーチ完了(下記「MCP Apps ホスト実装の参照スタック」節)。要旨:
Swift/iOS のオープンな MCP Apps ホストは存在しない(Claude iOS はクローズド)—
本アプリが初のオープン実装になる。移植元は公式 ext-apps リポジトリ一式。**

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
3. **P2: MCP Apps ホストスパイク(勝負どころ・判断ゲート)** — list-todos の `ui://` HTML を
   WKWebView で描画し、カード内操作 → tools/call → 再描画が往復するまで。
   ext-apps の App は postMessage ベースの JSON-RPC なので原理上成立するはずだが未踏。
   **通れば路線B確定、通らなければ路線A(ネイティブ契約描画)へ撤退**。
4. **P3: チャット(MVP フェーズ3)** — Anthropic API の tool-use ループ
   (tools/list → ツール定義変換 → tools/call)。ツール結果の `ui://` カードを
   チャット内にインライン描画。BYOK(設定画面+Keychain)。
   LLM エンドポイントは Services/LLM に抽象(SaaS 化時にプロキシへ差し替え)。
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
- caldav 側依存: **R-6(OAuth scope 分離)** — 第三者クライアント受け入れの前提整備。
  caldav 側で優先度上昇済み。並行して進む前提(P1 は現行認可でも繋がる)。

## 据え置き・起票のみ

- LLM プロキシ(Workers)+ メータリング/課金 — SaaS 化フェーズ(授業スコープ外)
- caldav 側 R-6(OAuth scope 分離)後の write scope 対応
- 月/週ビュー(アジェンダの粒度追加)— 画面が広い Swift ではカードより自由度が高い
- Push/ローカル通知(サーバー VALARM との関係整理が先)
- P4a(ネイティブ二方式描画)/ P4b(他 MCP サーバーデモ)— どちらを取るかは P3 後に判断

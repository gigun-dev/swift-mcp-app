# swift-mcp-app

**iOS 汎用 MCP Apps ホスト**(≒ claude.ai モバイルの自作版)。授業の Swift アプリ課題を
起点に開発する。最初の接続先は [caldav](https://github.com/gigun-dev/caldav)(自作 CalDAV
サーバー・MCP Apps 対応済み)——本アプリは caldav にとって DAV・claude.ai カスタムコネクタに
次ぐ **MCP 入口第3号**でもある。

## 方針(2026-07-15 第2版。初版「契約のネイティブ SwiftUI 描画」からの転換経緯は docs/next-directions.md)

1. **MCP クライアント** — [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) の
   `HTTPClientTransport` + OAuth 2.1(DCR→authorize→token のフルフロー)で
   `caldav.gigun-dev.workers.dev/mcp` に接続。**サーバー側の変更ゼロ**で繋がる
   (claude.ai とまったく同じ手順)。
2. **MCP Apps ホスト(コア)** — ツール結果が参照する `ui://` HTML カード
   (`text/html;profile=mcp-app`)を WKWebView サンドボックスで描画し、
   postMessage⇔MCP の JSON-RPC ブリッジでカード内操作をツール呼び出しに往復させる。
   ext-apps のホスト SDK は TypeScript のみで、iOS ネイティブの汎用ホストは前例がほぼ無い —
   **ホスト側プロトコルを Swift で実装すること自体が本体**。caldav の検証済み UI 資産
   (todos v3 / agenda カード)がそのまま画面になる。
3. **LLM オーケストレータ** — tools/list → LLM ツール定義変換 → tool-use ループ。
   ツール結果カードはチャット内にインライン描画。授業フェーズは BYOK(API キー手入力)。
   SaaS 化時は薄い LLM プロキシ(Workers)を課金の関所にし、フリーミアム/サブスクで
   LLM コストを回収(ユーザーは Claude サブスク不要)。アプリ側は LLM エンドポイントを
   1箇所に抽象しておき、プロキシ差し替えだけで移行する。

## MVP フェーズ

1. 接続: OAuth(ASWebAuthenticationSession)+ tools/list 表示
2. **MCP Apps ホストスパイク(判断ゲート)**: list-todos カードの描画と双方向操作。
   通れば本路線確定、通らなければネイティブ契約描画(路線A)へ撤退
3. チャット: LLM tool-use ループ + カードのインライン描画
4. (余力)ネイティブ二方式描画の対比 or 他 MCP サーバー接続デモ

## 開発環境

- iOS 17+ / Swift / SwiftUI
- XcodeGen + ローカル SwiftPM パッケージ(Kernel / Services)
- `make check` = swift build + swift test + lint（Kernel / Servicesの高速ゲート）
- `make lint` = SwiftFormat lint + SwiftLint strict（静的解析だけの再実行用。既存違反もbaselineで隠さない）
- `make app` = SwiftUIを含むiOSアプリ全体のgeneric Simulator向けbuild
- `make verify` = `make check` + `make app`（push前の最終ゲート）
- `make hooks` = trackedな`.githooks`を有効化。通常のmain pushだけ`make verify`を実行する
  （意図的に回避するときはGit標準の`git push --no-verify`）

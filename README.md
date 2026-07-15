# swift-mcp-app

[caldav](https://github.com/gigun-dev/caldav)(自作 CalDAV サーバー)の **Swift ネイティブ
コンパニオンアプリ**。授業の Swift アプリ課題を起点に、caldav の MCP 入口第3号
(DAV・claude.ai カスタムコネクタに次ぐ)として開発する。

## 方針(2026-07-15 確定。詳細は caldav 側 docs/next-directions.md「Swift コンパニオン」)

1. **MCP クライアント** — [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk) の
   `HTTPClientTransport` + OAuth 2.1(DCR→authorize→token のフルフロー対応)で
   `caldav.gigun-dev.workers.dev/mcp` に接続。**サーバー側の変更ゼロ**で繋がる
   (claude.ai とまったく同じ手順)。
2. **LLM オーケストレータ** — tools/list → LLM ツール定義変換 → tool-use ループ。
   授業フェーズは BYOK(API キー手入力)。SaaS 化時は薄い LLM プロキシ(Workers)を
   課金の関所にし、フリーミアム/サブスクで LLM コストを回収(ユーザーは Claude サブスク不要)。
   アプリ側は LLM エンドポイントを1箇所に抽象しておき、プロキシ差し替えだけで移行する。
3. **UI は EventKit でなく MCP 直** — caldav の TodosViewModel / EventsViewModel 契約
   (UI 技術非依存に設計済み。caldav 側 docs/modeling/12 §3)を SwiftUI でネイティブ描画。
   共有カーネル(contract + 純関数)戦略の3つ目の消費者。
   情報設計は todos カード v3(一覧=走査 / 選択=インライン編集 / 詳細=ページ /
   プリセット chips)を SwiftUI に写す。

## MVP フェーズ

1. 接続: OAuth(ASWebAuthenticationSession)+ tools/list 表示
2. リマインダークライアント: list-todos → SwiftUI 一覧、complete / create
3. チャット: LLM tool-use ループ(自然言語でタスク操作)
4. (余力)カレンダー: list-events-expanded / get-freebusy(caldav 側 E-3 の完了に依存)

## 未確定(授業の制約待ち)

- 期限・個人/チーム・評価観点 → パッケージ構成と MVP の切り方に反映

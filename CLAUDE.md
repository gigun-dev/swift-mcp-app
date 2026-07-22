# swift-mcp-app

**iOS 汎用 MCP Apps ホスト**(≒ claude.ai モバイルの自作版)。授業の Swift アプリ課題を
起点に開発する。任意の MCP サーバーに OAuth 2.1 で繋ぎ、チャットで LLM がツールを叩き、
ツール結果の `ui://` HTML カード(MCP Apps / SEP-1865)を WKWebView サンドボックス +
postMessage⇔MCP ブリッジで描画・双方向操作できるホストアプリ。

最初の(最良の)接続先は [caldav](https://github.com/gigun-dev/caldav)(自作 CalDAV サーバー・
ローカル: `~/ghq/github.com/gigun-dev/caldav`)。caldav は MCP Apps 対応済み
(todos v3 / agenda カード、`@modelcontextprotocol/ext-apps` 製)で、本アプリは
DAV・claude.ai カスタムコネクタに次ぐ **MCP 入口第3号**でもある。

**コア価値: MCP Apps のホスト側プロトコルを Swift で実装する + LLM オーケストレーション。**
この2つに寄与しない機能は後回し。iOS ネイティブの汎用 MCP Apps ホストは前例がほぼ無く、
ext-apps のホスト SDK も TypeScript のみ — 「ホスト側を Swift で実装した」こと自体が主張。
(旧コア価値「契約のネイティブ SwiftUI 描画」= 路線A は撤退先として保持。
経緯は docs/next-directions.md「路線の定義」)

長期ビジョン(設計判断はこれを裏切らないこと):
1. **SaaS 展開** — 授業フェーズは BYOK(API キー手入力)だが、LLM 呼び出しは
   エンドポイント1箇所に抽象しておき、将来は薄い LLM プロキシ(Workers)へ差し替えるだけで
   フリーミアム/サブスク課金(ユーザーは Claude サブスク不要)に移行できる構造を保つ。
   「caldav 専用クライアント」は機能だが「モバイル MCP ホスト」は製品になりうる。
2. **汎用ホストとしての中立性** — ブリッジ・チャット・OAuth は caldav 固有の知識を持たない。
   caldav 固有の解釈(DTO・UI 文法)が必要になる場面(路線A撤退・P4a)では Kernel に隔離する。

## 技術スタック

- Swift / SwiftUI(iOS 17+。授業指定があれば従う)
- MCP: [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)
  (ローカル: `~/ghq/github.com/modelcontextprotocol/swift-sdk`)。
  `HTTPClientTransport`(Streamable HTTP)+ OAuth 2.1 フルフロー(DCR→authorize→token)。
  接続先は本番 `https://caldav.gigun-dev.workers.dev/mcp`(サーバー変更ゼロで繋がる —
  claude.ai と同じ手順。DCR は `token_endpoint_auth_method:"none"`)。
  MCP Apps は swift-sdk に専用サポートが無いが、基本プリミティブ(tools・embedded resource・
  resources/read)は 2025-11-25 プロトコルで対応済み。ホスト側ブリッジ(WKWebView +
  `WKScriptMessageHandler` で ext-apps の App と JSON-RPC 会話)は本アプリの自前実装。
- LLM: **OpenAI 互換 API**(`/chat/completions` + tools)。tool-use ループは自前実装。
  キーは Keychain 保存・BYOK。設定にプリセット(OpenAI / OpenRouter / Groq / Together …)を
  持つが、これは base URL の既定値を埋めるだけ — **互換エンドポイントならベンダーを問わない**
  (ビジョン1「LLM 呼び出しはエンドポイント1箇所に抽象」の実装形)。既定モデルは
  `gpt-5.4-mini`(軽量・低コスト。tool-use は毎ターン全ツール定義を送るためトークン費が乗る)。
  ※初期案は Anthropic API 直叩きだったが、汎用ホストとしての中立性(ビジョン2)を
  LLM 側にも及ぼすため互換 API へ寄せた。Anthropic を使う場合も互換ゲートウェイ経由になる。
- 雛形: **XcodeGen**(project.yml → `xcodegen generate`、.xcodeproj は git 管理外)+
  Kernel/Services は**ローカル SwiftPM パッケージ**(`swift test` が Xcode なしで回る)。
- 統合検証: `make check`(swift build + swift test + lint)はKernel/Servicesの高速gate、
  `make app`はSwiftUIを含むiOSアプリ全体のbuild、`make verify`は両方を束ねたpush前の最終gate。
  静的解析だけを再実行するときは`make lint`(SwiftFormat lint + SwiftLint strict)を使い、
  既存違反もbaselineで隠さない。clone直後は`make hooks`でtrackedな`.githooks`を有効化し、通常の
  main pushで`make verify`を実行する。意図的な非常時だけGit標準の`git push --no-verify`で迂回できる。
  (CI 導入は提出形態が固まってから)。

## 開発プロセス(caldav から移植した規律)

- **契約の正は caldav 側**: MCP Apps のサーバー側実装(`registerAppResource` /
  `registerAppTool`・`_meta.ui.resourceUri`)は caldav の `src/presentation/mcp/server.ts`、
  カード実体は `src/presentation/mcp/ui/` を読む。ブリッジプロトコルの正は
  `@modelcontextprotocol/ext-apps`(SEP-1865・spec `specification/2026-01-26/apps.mdx`)。
  写経した契約には出典をコメントで残す。
  ズレたら caldav 側 docs を先に直す。
- **UI はモックで合意してから実装**: SwiftUI プレビュー or HTML モックで方向を
  ユーザーと合意 → 実装(caldav の todos v3 / agenda で確立した進め方)。
- **実装は subagent に委譲、main は設計・レビュー**(ユーザーのグローバル方針)。
- 検証は実機/シミュレータ + caldav 本番の D1 生 ICS 裏取り(caldav 側の検証メモ参照)。
  **シミュレータでの E2E 検証手順とハマりどころは skill `ios-e2e-verify`**
  (`.claude/skills/ios-e2e-verify/SKILL.md`)に切り出した — 環境変数の渡し方
  (`--setenv` は使えず `SIMCTL_CHILD_` を使う)、スパイクハーネス(`MCPHOST_SPIKE`)で
  LLM も認証も無しに検証できる範囲、タップ座標系のズレ(918px と 402pt)、
  **資格情報を入力せずに通す方法**(`MCPHOST_LLM_KEY` の env 経路)など。
  常時ロードは無駄なので skill にしてある(検証の話題になったときだけ読まれる)。

## アーキテクチャ方針

レイヤーは薄く3つ。依存は常に内側へ。

```
Sources/
├── Kernel/        # プラットフォーム非依存の純関数層: MCP DTO の Codable、ブリッジの
│                  # メッセージ型(JSON-RPC エンベロープ)、(路線A撤退時は契約解釈もここ)
├── Services/      # MCP クライアント(接続・OAuth・tools/call・resources/read)、
│                  # AppsBridge(WKWebView⇔MCP の JSON-RPC 仲介)、
│                  # LLM オーケストレータ(tool-use ループ)、Keychain
└── Features/      # SwiftUI: チャット / サーバー接続・設定 / カード表示(WKWebView ラッパー)
```

- Kernel はプラットフォーム非依存(swift-testing で高速にテスト)。
- LLM エンドポイントは `Services/LLM/` の1箇所に抽象(ビジョン1)。
- AppsBridge は接続先サーバーに対して中立(ビジョン2)。

## 情報の書き分け方針(caldav と同一・このリポジトリでも基本ルール)

- **コード = How** / **テスト = What** / **コミットログ = Why** / **コメント = Why not**。
- **コメントはコードと同量レベルでベッタベタに書く。** 詳細は `.claude/rules/comments.md`
  (コード編集時に自動ロード)。要旨: 意図と経緯を残す・ボツ案は財産・
  消すのは「事実として誤り」のときだけ。

## 現在地・次の作業(セッション引き継ぎ)

- 正典は **`docs/next-directions.md`** — SessionStart フック(`.claude/settings.json`)が
  頭(`session-head-end` マーカーまで)を自動注入する。作業の区切りごとに必ず更新
  (完了は打ち消し線+✅、変化は `> 日付 更新:` を積層。計画は消さない)。
- 時系列の生記録は **`docs/log.md`** に追記(追記専用アーカイブ)。

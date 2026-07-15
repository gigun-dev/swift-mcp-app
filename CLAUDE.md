# swift-mcp-app

[caldav](https://github.com/gigun-dev/caldav)(自作 CalDAV サーバー・ローカル:
`~/ghq/github.com/gigun-dev/caldav`)の **Swift ネイティブコンパニオンアプリ**。
授業の Swift アプリ課題を起点に、caldav の **MCP 入口第3号**(DAV・claude.ai
カスタムコネクタに次ぐ)として開発する。

**コア価値: caldav の MCP 契約を SwiftUI でネイティブに消費する + LLM オーケストレーション。**
この2つに寄与しない機能は後回し。

長期ビジョン(設計判断はこれを裏切らないこと):
1. **SaaS 展開** — 授業フェーズは BYOK(API キー手入力)だが、LLM 呼び出しは
   エンドポイント1箇所に抽象しておき、将来は薄い LLM プロキシ(Workers)へ差し替えるだけで
   フリーミアム/サブスク課金(ユーザーは Claude サブスク不要)に移行できる構造を保つ。
2. **caldav 側との共有カーネル** — UI は EventKit でなく **MCP 直**。
   TodosViewModel / EventsViewModel(caldav 側 `docs/modeling/12` §3 が契約の正)を
   SwiftUI で描画する。契約の解釈ロジック(DTO デコード・日付整形・セクショニング)は
   UI から分離した純関数層に置き、caldav の ui/ 純関数群と対応づける。

## 技術スタック

- Swift / SwiftUI(iOS。授業の要件に従い最小 OS バージョンは決定待ち)
- MCP: [swift-sdk](https://github.com/modelcontextprotocol/swift-sdk)
  (ローカル: `~/ghq/github.com/modelcontextprotocol/swift-sdk`)。
  `HTTPClientTransport`(Streamable HTTP)+ OAuth 2.1 フルフロー(DCR→authorize→token)。
  接続先は本番 `https://caldav.gigun-dev.workers.dev/mcp`(サーバー変更ゼロで繋がる —
  claude.ai と同じ手順。DCR は `token_endpoint_auth_method:"none"`)。
- LLM: Anthropic API(tool-use ループを自前実装)。キーは Keychain 保存・BYOK。
- ビルド/検証: Xcode + SwiftPM。`make check` 相当(swift build + swift test + lint)を
  Makefile に整備する(CI 導入は授業の提出形態が決まってから)。

## 開発プロセス(caldav から移植した規律)

- **契約の正は caldav 側**: ツール入力スキーマ・DTO の形は caldav の
  `src/presentation/mcp/server.ts` と `docs/modeling/12` を読む。写経した契約には
  「caldav 側の出典」をコメントで残す。ズレたら caldav 側 docs を先に直す。
- **UI はモックで合意してから実装**: SwiftUI プレビュー or HTML モックで方向を
  ユーザーと合意 → 実装(caldav の todos v3 / agenda で確立した進め方)。
- **実装は subagent に委譲、main は設計・レビュー**(ユーザーのグローバル方針)。
- 検証は実機/シミュレータ + caldav 本番の D1 生 ICS 裏取り(caldav 側の検証メモ参照)。

## アーキテクチャ方針

レイヤーは薄く3つ。依存は常に内側へ。

```
Sources/
├── Kernel/        # 契約層: MCP DTO の Codable・日付/繰り返し整形・セクショニング(純関数・UI 非依存)
├── Services/      # MCP クライアント(接続・OAuth・tools/call)、LLM オーケストレータ(tool-use ループ)、Keychain
└── Features/      # SwiftUI: リマインダー一覧 / アジェンダ / チャット(Kernel+Services を消費)
```

- Kernel はプラットフォーム非依存(swift-testing で高速にテスト)。
- LLM エンドポイントは `Services/LLM/` の1箇所に抽象(ビジョン1)。
- 情報設計は caldav の todos v3 / agenda カードの文法(一覧=走査 / 選択=インライン編集 /
  詳細=ページ / プリセット chips)を SwiftUI に写す。

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

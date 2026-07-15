# 次セッションの方向性(2026-07-15 初版)

> **位置づけ**: 恒久ドキュメント(セッション引き継ぎの正典)。セッション開始時にまず読む。
> **更新ルール**: 計画は消さない。完了は打ち消し線 + ✅、状況変化は該当箇所の直下に
> `> **YYYY-MM-DD 更新:** ...` の引用ブロックを積層する。大きな節目で全体を棚卸しする。
> 時系列の生記録は docs/log.md に追記(追記専用アーカイブ)。運用は caldav 側と同一。

**現在地(2026-07-15)**: リポジトリ初期化 + 開発基盤(CLAUDE.md・コメント規律・
本正典+SessionStart フック)を caldav から移植した段階。**コードは未着手**。
Xcode プロジェクト/SwiftPM の雛形もまだ無い。

**未確定(着手前にユーザーへ確認)**:
- 授業の制約: 期限・個人/チーム・評価観点・最小 iOS バージョン・提出形態
- GitHub リモート(public/private)を作るか

**次の優先順位**:
1. **P0: プロジェクト雛形** — Xcode プロジェクト(SwiftUI App)+ SwiftPM で
   Kernel/Services/Features の3レイヤー骨格 + swift-sdk 依存追加 + Makefile
   (`make check` = swift build + swift test)。
2. **P1: 接続(MVP フェーズ1)** — OAuth 2.1(ASWebAuthenticationSession +
   swift-sdk の認可フロー)→ 本番 /mcp へ接続 → tools/list を画面表示。
   「繋がった」が最初のマイルストーン。トークンは Keychain。
3. **P2: リマインダークライアント(MVP フェーズ2)** — Kernel に TodosViewModel の
   Codable + 整形純関数(caldav の契約を写経・出典コメント必須)→ list-todos 一覧
   (セクション: 期限切れ/今日/今後/期日なし/完了)→ complete/reopen トグル →
   create-todo。情報設計は caldav todos v3 の文法を SwiftUI に写す。
4. **P3: チャット(MVP フェーズ3)** — Anthropic API の tool-use ループ
   (tools/list → ツール定義変換 → tools/call)。BYOK(設定画面+Keychain)。
   LLM エンドポイントは Services/LLM に抽象(SaaS 化時にプロキシへ差し替え)。
5. **P4(余力): アジェンダ** — EventsViewModel(caldav E-3)。caldav 側 S2 の
   アジェンダカードと同じ情報設計。

<!-- session-head-end: ここまでが SessionStart フックで自動注入される「頭」。 -->

## 参照(契約・設計の正は caldav 側)

- ツールスキーマ・DTO: caldav `src/presentation/mcp/server.ts` /
  `docs/modeling/12-vevent-agentic.md`(Event DTO / EventsViewModel / Task DTO 系)
- OAuth の暗黙契約: caldav `docs/next-directions.md` 方向性 E
  (DCR `token_endpoint_auth_method:"none"` / Accept: text/event-stream)
- UI 文法: caldav `docs/modeling/ui-mockups/`(todos-refined-v3 / agenda-v1)
- SaaS 構成方針(LLM プロキシ・課金): caldav docs/next-directions.md「Swift コンパニオン」節

## 据え置き・起票のみ

- LLM プロキシ(Workers)+ メータリング/課金 — SaaS 化フェーズ(授業スコープ外)
- caldav 側 R-6(OAuth scope 分離)後の write scope 対応
- 月/週ビュー(アジェンダの粒度追加)— 画面が広い Swift ではカードより自由度が高い
- Push/ローカル通知(サーバー VALARM との関係整理が先)

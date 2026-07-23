# 08. OAuth トークンライフサイクル設計(2026-07-23 調査・正典)

> 位置づけ: swift-mcp-app ホストのトークン管理設計の正。一次資料調査(MCP Authorization
> 仕様 2025-06-18/2025-11-25・OAuth 2.1 draft-13・workers-oauth-provider README・
> Claude 公式 connector docs)に基づく。調査の生データは docs/log.md 2026-07-23 参照。

## 経緯(Why)

claude.ai iOS の caldav カード描画失敗の切り分けで、正体が「access token 失効
(workers-oauth-provider 既定 TTL 1時間)後、iOS のカード描画パスだけ refresh せず
401 invalid_token → 『サーバーに接続できません』」と確定した(web は refresh して描画継続)。
これは Anthropic 側の既知バグ系統(claude-ai-mcp#228・claude-code#65036)だが、
自作ホストが同じ轍を踏まないためのライフサイクル設計をここに固定する。

## 規範(出典付き)

- サーバーは無効/失効トークンに 401 を返す(MUST)。クライアントは WWW-Authenticate を
  パースし 401 に適切に応答できなければならない(MUST)。認可ヘッダは毎 HTTP リクエスト必須。
  (MCP Authorization 仕様 — https://modelcontextprotocol.io/specification/2025-11-25/basic/authorization)
- access token は short-lived SHOULD(MCP 仕様)。具体秒数の規定はなし。実務レンジ 5分〜1時間。
- 公開クライアント(token_endpoint_auth_method: none = 本アプリも claude.ai も該当)に対し、
  AS は refresh token を rotate しなければならない(MCP 仕様が MUST と明示。OAuth 2.1 §4.3.1 参照)。
- Claude 公式の実装形(参照ベスプラ): 「401 で反応的に refresh + 保存 expiry の5分前から
  先回り refresh」のハイブリッド(https://claude.com/docs/connectors/building/authentication)。

## 本アプリ(ホスト)の設計原則

1. **ハイブリッド refresh**: 送信直前に `expires_at - スキュー(5分 or TTL の10%)` を過ぎて
   いたら先回り refresh。加えて 401 受信時に1回だけ refresh → 元リクエスト再試行の
   反応型フォールバック。判定は HTTP レイヤのトークンプロバイダ1箇所に集約する。
2. **single-flight**: refresh は actor で直列化し、進行中 refresh があれば後続はその Task を
   await して結果を共有する。rotation 下で並行 refresh すると2本目以降が旧 refresh token で
   `invalid_grant` 自爆するため(tool-use ループ・複数カードの resources/read は並行する)。
3. **原子的保存**: 新 access/refresh/expiry を1レコードとして Keychain へ原子更新。
   保存成功まで旧 refresh token を捨てない(workers-oauth-provider は2本猶予があるが依存しない)。
   Keychain は server(canonical resource URI)ごと1エントリ・
   `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`。
4. **失敗の区別**: `invalid_grant`(恒久失効)→ 自動 refresh を諦めて再認可導線を明示表示
   (サイレント 401 ループ = claude.ai iOS の失敗形をやらない)。一過性エラー → 指数バックオフ。
   タイムアウト目安: discovery 10s / refresh 30s。
5. **SSE 長命接続**: トークンは接続確立時ヘッダに固定される。失効前に proactive refresh し、
   401/切断検知で refresh → 再接続。SSE と POST は同じプロバイダから同じ最新トークンを使う。

## caldav(サーバー側)への帰結

- `accessTokenTTL` は既定 3600s を維持(short-lived SHOULD に合致)。TTL 延長で iOS バグを
  凌ぐ案は却下: 漏洩 blast radius 拡大・根本原因隠蔽・TTL 超過で同じループに戻る。
- refresh token rotation は workers-oauth-provider が仕様準拠で実装済み(2本猶予付き)。変更不要。
- refresh token 失効時は RFC 6749 準拠の `invalid_grant` を返す(Claude が要求)。
  401 には `WWW-Authenticate: Bearer resource_metadata="..."` を必ず付ける。

## Anthropic への報告の建て付け

二段構え: (1) MCP 仕様が MUST とする「401 への適切な応答」を満たさない、
(2) 自社 docs が約束する refresh 動作(上記ハイブリッド)の不履行。
決め手の証拠: 同一サーバー・同一 TTL で web は refresh して描画継続・iOS カード描画パスのみ
401 ループ(サーバー準拠の対照実験)+ caldav ログで refresh_token grant が0件 +
request_id(req_011CdK4EGbphwRXcNpmLbsPy)。既知 issue claude-ai-mcp#228(proxy パスの
refresh 未実装)・claude-code#65036 と同根、iOS カード描画パス固有としては新規報告が妥当。

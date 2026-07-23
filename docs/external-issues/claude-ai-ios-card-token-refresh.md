# [外部・未起票] claude.ai iOS: MCP Apps カード描画パスが access token を refresh しない

> 位置づけ: **我々の責務外(Anthropic 側)と推定されるバグの観察記録**。誤解の可能性を
> 残した一次証拠の台帳であり、確度が上がったら末尾の英文ドラフトで upstream へ起票する。
> ステータス: 未起票(2026-07-23)。関連: docs/design/08(OAuth ライフサイクル設計)。

## 症状

claude.ai **iOS アプリのみ**、caldav(OAuth 2.1 必須の自作 MCP サーバー)のカードが
「MCPアプリの読み込みに失敗しました サーバーに接続できません」で描画されない。
同一会話・同一コネクタで web / Desktop は描画される。認証不要のサーバー(TDR Wait Times)の
カードは iOS でも描画される。

## 一次証拠(2026-07-23 実測)

1. 失敗時、caldav の Workers ログにカード用 resource 取得は到達せず、近接時刻に
   `OAuth error response: 401 invalid_token` を記録(22:19 JST の失敗は
   request_id `req_011CdK4EGbphwRXcNpmLbsPy`、iOS 表示は「The connector's server isn't
   responding」)。同時間帯の `Claude-User` UA の tools/call は全成功(テキスト応答は出る)。
2. コネクタを削除→再作成(新トークン発行)した直後は、最小診断カード(diag-card・1243B・
   SDK 無し)も todos/agenda(1MB 超バンドル)も **iOS で描画成功** → サイズ説は棄却。
3. caldav は `@cloudflare/workers-oauth-provider`(accessTokenTTL 既定 3600s・
   refresh rotation 実装済み)。失敗期間中、サーバーログに refresh_token grant の試行なし。
4. 対照: web のカード描画パスは同一失効トークン条件から回復して描画できていた。

## 推定される原因

access token 失効(1時間)後、iOS アプリの**カード描画(ui:// resource 取得)パスだけ**が
refresh を行わず、失効トークンのまま 401 を受けて「サーバー無応答」と誤表示する。
tools/call パスと web のカード描画パスは refresh される。

## 誤解の可能性(反証があれば更新)

- 「web は refresh した」は直接観測ではない(web が描画できた事実からの推定)。web 側も
  別要因(セッション再認可のタイミング等)だった可能性は残る。
- 22:19 の 401 と iOS 失敗の対応は時刻相関で、request 単位の突合はしていない
  (Workers ログに UA が 401 行へ join されないため)。
- 再現条件「トークン失効後の iOS カード描画」は1時間待てば再試行できる。次回失効時に
  ①iOS カード失敗 ②同時刻の web カード成功 ③サーバーログ 401 + refresh 試行ゼロ、の
  3点セットを再取得できれば確度が上がる。

## 関連する既知 issue(同根と推定)

- anthropics/claude-ai-mcp#228 — proxy パス(claude.ai)で OAuth refresh が一切試行されない。
  サーバーログに refresh 0 件という同じ観測。Open・公式応答なし。
- anthropics/claude-code#65036 — 有効な refresh token があるのに access token 失効時に
  refresh せず再認可へ直行。多数の重複あり。

## 規範上の位置づけ(起票時の建て付け)

- MCP Authorization 仕様(2025-11-25)はクライアントに「WWW-Authenticate をパースし
  401 へ適切に応答する」を MUST で課す。refresh 手順そのものは OAuth 2.1 委譲のため
  「仕様違反」と一条で断ずるのは弱く、**「自社 docs の約束との矛盾」を主軸にする**:
  Claude 公式 connector docs は「401 で反応的に refresh + expiry 5分前から先回り refresh」を
  明文で約束している(https://claude.com/docs/connectors/building/authentication)。

## 英文 issue ドラフト(起票時にコピー)

Title: iOS app: MCP Apps card rendering path never refreshes expired OAuth access tokens (401 loop), while web renders fine

Body:

On the claude.ai iOS app, MCP Apps (ui://) cards from an OAuth-protected MCP server fail with
"Failed to load MCP app / cannot connect to server" once the access token expires, while the
same connector renders cards fine on web. Tool calls (text results) keep working on iOS.

Server: self-hosted MCP server on Cloudflare Workers using @cloudflare/workers-oauth-provider
(access token TTL 3600s, refresh token rotation enabled, RFC 9728 metadata, 401 with
WWW-Authenticate). Spec-compliant behavior verified by the web client recovering on the
same connector.

Evidence:
- Server logs show `401 invalid_token` at the failure time (request_id
  req_011CdK4EGbphwRXcNpmLbsPy) and zero refresh_token grant attempts during the failure window.
- Deleting and re-adding the connector (fresh token) immediately fixes card rendering on iOS —
  both a 1.2KB minimal card and a 1MB+ bundled card render, ruling out size limits.
- The iOS error UI says "The connector's server isn't responding", which mis-attributes an
  auth failure (401) to server unavailability.

This looks like the iOS-app card-rendering counterpart of claude-ai-mcp#228 (proxy path never
attempts OAuth refresh) and claude-code#65036. Per your docs ("Claude refreshes tokens
reactively on a 401 response, with a proactive refresh up to five minutes before the stored
expiry" — /docs/connectors/building/authentication), the card rendering path on iOS does not
implement this. Please route 401s from ui:// resource fetches through the same token refresh
path used by tool calls, and surface auth errors as auth errors (re-auth prompt) instead of
"server isn't responding".

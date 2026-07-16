# caldav MCP Apps カードへのフィードバック(ネイティブ iOS ホストからの発見)

> 2026-07-15 起票。swift-mcp-app(iOS ネイティブの MCP Apps ホスト・WKWebView)で
> caldav の todos v3 / agenda カードを**素の HTML のまま**ホストして判明した、
> **caldav 側で対処すべき**事項をまとめる。ここは swift-mcp-app リポジトリだが、
> 一次資料は caldav `src/presentation/mcp/ui/`。修正は caldav リポジトリで行う。
>
> 前提(重要): これらは「ネイティブ WKWebView ホスト」で初めて表面化する。claude.ai は
> カードを iframe に入れ、外側の viewport/ズーム方針を claude.ai が持つため、カード単体の
> viewport や文字サイズの粗が隠れていた。ネイティブホストは WKWebView 自体が最外殻なので、
> カードが宣言する viewport と文字サイズがそのまま効く。

## まとめ(優先度順)

| # | 事項 | 深刻度 | 対処場所 |
|---|---|---|---|
| 1 | 入力欄の文字サイズ < 16px で iOS の focus zoom が発動 | 中(操作性) | caldav CSS |
| 2 | complete 時の視覚変化が乏しい/アニメーションが出ないことがある | 低(UX) | caldav カード JS |
| 3 | list-todos の calendarId 省略時 tasks 暗黙フォールバックが複数 VTODO で lossy | 中(正しさ) | caldav ツール設計 |

---

## 1. 入力欄 < 16px による iOS focus zoom(要対処)

**症状**: カード内のテキスト入力(メモ textarea など)にフォーカスすると、iOS が
その入力を「読める大きさ」にしようと**自動でページを拡大する**。ネイティブホストでは
これがカード全体のズームとして見え、操作の邪魔になる。

**原因**: iOS Safari/WebKit は **font-size が 16px 未満**の入力にフォーカスすると
auto-zoom する仕様。caldav カードの入力・テキストは 16px 未満が多い:
- `.d-notes`(メモ textarea)= **13px**(`ui/agenda-app.ts:207` ほか。todos も同系)
  → focus zoom を踏む代表格。
- `.d-title`(タイトル input)= 16px → これは OK。
- カード全体でも font-size は 10.5〜13px が大半(表示専用テキストは focus zoom には
  無関係だが、可読性の観点でも小さめ)。

**正しい対処(caldav 側)**: **フォーカスされうる入力(textarea / type=text / 編集可能要素)を
16px 以上にする。** 最小限なら `.d-notes` を 13px → 16px。表示だけのラベルは対象外。

**やってはいけない対処**: ホスト側で `maximum-scale=1` や zoom ロックをかけて封じるのは、
ピンチズーム(アクセシビリティ)まで殺すうえ、根本(小さすぎる文字)を隠すだけ。
→ swift-mcp-app 側では**採らない**方針を確定済み(ホストは zoom を触らない。
`Sources/Features/AppCard/AppCardView.swift` のボツ案コメント参照)。ホストが残す介入は
「ダブルタップ・ツー・ズーム認識器の無効化」(タップ遅延対策・ピンチズームは残す)のみ。

**補足**: カードの viewport 宣言は `width=device-width, initial-scale=1`(todos-app.ts:85 /
agenda-app.ts:33)で妥当。`maximum-scale` を足す必要はない(足すとピンチズームを失う)。

## 2. complete 時の視覚フィードバックが乏しい(UX・低優先)

**症状**: todos をチェックして complete したとき、見た目の変化が
**優先度マーク(!)が消えるだけ**に見え、状態が変わった実感が薄い。becoming-done の
アニメーションが出ないケースもあり、往復している手応えが弱い(2026-07-15 実機観測。
tasks の「追加へ1」を complete → ! が消えるだけで他は不変に見えた)。

**切り分け(ホスト側は正常と確認済み)**: ホストのログで **1タップ = 1 回の
`tools/call update-todo` 往復・重複ゼロ**を確認済み。ブリッジは各操作を忠実に
プロキシしており、多段の見え方・アニメーションの有無は **caldav カード(todos-entry)の
レンダリング/演出ロジック**が決めている。

**提案(caldav 側・任意)**: complete 時に「取り消し線 + チェック + becoming-done の
短い演出」が常に一貫して出ると、往復の手応えが上がる。優先度マークの消滅だけが
唯一の差分になる状態は避けたい。ただし意図した簡潔さなら現状維持でも可。

## 3. list-todos の calendarId 暗黙フォールバックが複数 VTODO で lossy(設計論点)

> 2026-07-16 起票。swift-mcp-app のチャットで LLM が list-todos を叩いた際に表面化。
> ツールステップ展開 UI で「リクエスト = `{}`・レスポンス = tasks コレクションのみ」を目視して気づいた。

**事象**: `list-todos` は `calendarId` 省略時に **暗黙で `tasks` にフォールバック**する
(ツールスキーマ「対象コレクション ID。省略時は "tasks"」)。ところが実アカウントには
VTODO コレクションが**複数**ある(`list-calendars` の実測: `tasks` と `reading-list` の2つ)。
そのため LLM が「todo を全部見せて」の意図で `{}`(引数なし)で呼ぶと、**`reading-list` の
TODO を静かに取りこぼす**。レスポンスに `"calendarId":"tasks"` が echo されるので観測は可能だが、
モデルもユーザーも「これが全部」と誤認しやすい。

**なぜ MCP ツールとして気になるか**: MCP ツールは LLM が叩く前提で、暗黙デフォルトは
「モデルがデフォルトの存在と射程を知らないまま部分結果を全体と誤認する」事故になりやすい。
DAV クライアント(人間 UI)なら「今 tasks リストを見ている」文脈が画面にあるが、LLM 経由では
その文脈が無い。単一コレクションのアカウントなら無害だが、複数だと「正しさ」の問題になる。

**caldav 側の選択肢(いずれか)**:
- (A) ツール説明を明示化: 「複数の VTODO コレクションがあり得る。省略時は `tasks` のみを返す。
  全体を見るには list-calendars で発見して各 calendarId を指定せよ」と description に書く(最小・低コスト)。
- (B) 省略時は**全 VTODO コレクションを横断集約**して返す(「todo を見せて」の自然な意図に一致。
  ただし件数増・パフォーマンス・calendarId の混在表示をどう返すか要設計)。
- (C) `calendarId` を必須化してデフォルトを廃止(モデルに list-calendars 発見を強制・最も明示的だが摩擦大)。

**ホスト側(swift-mcp-app)の対処(caldav とは別レイヤー・任意)**: system prompt で
「todo/予定を扱う前に list-calendars でコレクションを発見し、関連する各リストを問い合わせる」よう
誘導する。実際 gpt-5.4-mini は list-todos の前に list-calendars を先呼びする挙動を見せており
(当初「無駄」と見えたが)複数コレクション対応としては正しい本能。ただし発見後に `tasks` だけでなく
`reading-list` も引くところまでは誘導が要る。→ これは caldav の対処とは独立に、ホストの
モデル誘導(将来のコスト/品質チューニング)で扱う。

**優先度**: 中(正しさ)。単一コレクション運用なら据え置き可。複数運用を想定するなら (A) が最小対処。

---

## 参考: ネイティブホストで確認できた「良い点」(caldav 側の対処不要)

- caldav の todos v3 カードは **1バイトの改変もなく** WKWebView 上で
  initialize → 描画 → complete 往復まで完動した(`@modelcontextprotocol/ext-apps` の
  App がそのまま動く)。MCP Apps の契約遵守は良好。
- `_meta.ui.resourceUri` の新旧2キー併記・`text/html;profile=mcp-app` の mimeType・
  ext-apps の autoResize(size-changed)いずれもホストから素直に消費できた。

# 09 ツール許可の設定画面 + ランタイム確認シート(R4 の UI 露出)

> 位置づけ: queue 7(ツール許可ゲート R4・`67a7b3d`)で入れた**判定と永続化**の上に、
> 「決定の一覧・変更・リセット UI」と「ランタイム確認 UI の作り直し」を載せる設計。
> 参照は claude.ai の iOS/web コネクタ権限画面(2026-07-24 ユーザー提供スクショ)。
> モックは scratchpad/permission-mock.html で方向合意済み。

## 前提(既にあるもの・queue 7)

- `Kernel/Interaction/ToolPermissionPolicy.swift`:
  - `ToolPermissionDecision`(allow/ask/deny・UserDefaults raw)。
  - `evaluate(annotations:decision:) -> ToolGateOutcome`(proceed/confirm/deny)。
    **性悪説**: 既定 `.ask` は confirm、唯一の緩和は `readOnlyHint==true` のときだけ proceed。
  - `ToolAnnotations.isLikelyDestructive`(未申告は true=破壊的とみなす・警告表示用)。
- `Services/Chat/ToolPermissionStore.swift`: `(serverURL, originalToolName) → decision` を UserDefaults 永続化。
  既定 ask はキーを持たない(保存は allow/deny だけ)。
- `Features/Chat/ToolConfirmationDialog.swift`: 現状は `confirmationDialog`(素のアクションシート)。**作り直す。**

## 決定(2026-07-24・ユーザー合意)

1. **設定のナビは「詳細プッシュ」型**(claude.ai iOS 系)。行内セグメント切替(claude.ai web 系)は
   **採らない** —— モバイル幅ではセグメントがツール名の表示幅を圧迫するため。
   **行タップ→ボトムシートはアンチパターンなので不可**(ユーザー明言)。プッシュ遷移のみ。
2. **readOnly は既定「常に許可」、副作用ありは既定「確認する」**(業界デファクト)。
   これは判定(evaluate)では既に成立(readOnly は ask でも proceed)。**設定画面の既定表示**を
   これに合わせる(下記「既定表示の写像」)。
3. **ランタイム確認は detent セミモーダル**(`.medium`→`.large`)。折り畳みで「ツール名+ボタン」、
   引き出すと引数 JSON 全文+破壊警告。素のアクションシートを置換。
4. アイコンは **lucide**(check-circle=常に許可 / hand=承認が必要 / ban=ブロック)。claude.ai と語彙を揃える。

## 画面設計

### 画面1: コネクタ一覧(既存の設定に「ツールの権限」導線を足す)
- 登録済み MCP サーバーを行で並べ、各行にツール件数バッジ + `›`。タップで画面2へ。
  (claude.ai 画像1 相当。ServerRegistryStore.servers から生成・中立)。

### 画面2: コネクタ詳細(ツール一覧・状態ラベル + `›`)
- ヘッダ: コネクタ名・URL・「切断/削除」。
- 「ツールの権限」セクション: 現在接続の tools/list(originalToolName)を名前順で行に。
  各行 = **ツール名(幅いっぱい)+ 状態ラベル + `›`**。行内に切替コントロールは置かない(決定1)。
  - 状態ラベル文言: `常に許可` / `確認する` / `ブロック`。
- 行タップで画面3へプッシュ。
- (将来)セクション見出しに一括メニュー「すべて確認/すべて許可/カスタム」。初手スコープ外でよい。

### 画面3: ツール詳細(3択 + 説明)
- 3 択(縦積み・ラジオ相当・現在値にチェック): 常に許可 / 承認が必要(=ask) / ブロック(=deny)。
  各択に lucide アイコン + 1 行説明。
- その下にツールの **description**(tools/list の説明文)。破壊的なら「取り消せない操作かも」警告。
- 選択即保存(`ToolPermissionStore.setDecision`)。戻ると画面2のラベルへ反映。

### 既定/自動許可のベスプラ(2026-07-24 再調査・一次情報)

出典: MCP 公式ブログ「Tool Annotations as Risk Vocabulary」(blog.modelcontextprotocol.io 2026-03-16)、
Codex CLI の annotation 承認フレーム(codex.danielvaughan.com 2026-04-12)、VS Code Copilot approvals、
github-mcp-server issue #2483。要点:

- **保守的既定(未申告=確認)は全ソース一致で正しい。** 現行の性悪説既定を維持。
- **readOnly 自動許可は「サーバーを信頼している場合のみ」有効。** MCP 公式:「untrusted server の
  readOnlyHint は actionable でない —— 確認を省く判断はその hint を信じる場合にしか意味を成さない」。
  悪意あるサーバーは破壊的ツールを readOnly と偽れる。
- **Codex CLI は `readOnlyHint==true` かつ `openWorldHint==false` の両方**で初めて自動承認。
  read-only でも **open-world(外部システムに触れる)ツールは自動許可しない**。
- **安全の本体は決定的制御(サンドボックス/ネットワーク)に置き、annotations は UX にだけ使う。**
  「Hints inform decisions; contracts enforce them.」

**現行 `evaluate` の不足と精緻化(要 Kernel 変更・S1 で対応):**
1. openWorldHint を見ていない → read-only かつ open-world を自動許可してしまう。緩和条件に
   `openWorldHint != true` を **追加**する。
2. 信頼の軸が無い(どのサーバーの readOnly 主張も無条件に信じている)→ `trusted: Bool` を **追加**する。

**信頼モデル(この個人 MCP ホスト向けの決定案):** ユーザーが自分で URL を追加し OAuth 認証した行為
自体が trust シグナル。よって「ユーザー追加サーバー = trusted」を既定にすれば readOnly 自動許可の UX は
保てる。将来 claude.ai の「コネクタの検出」的なディレクトリ発見の未認証サーバーは `trusted=false` にして
自動許可しない。今は全サーバーがユーザー追加なので実質常に true だが、「盲信」でなく「根拠のある trust」に
なる(annotations だけで安全を決めない、というベスプラに沿う)。

精緻化後の緩和条件(`evaluate`):
```
.ask のとき: proceed ⟺ trusted && readOnlyHint == true && openWorldHint != true / それ以外 confirm
```
`.deny`→deny、`.allow`→proceed は不変。openWorldHint 追加で「read-only な web 系読み取り」等は
自動許可されず確認に回る(より安全側・spec 準拠)。destructiveHint は従来どおり **確認を強める警告表示**に
だけ使い、緩和には一切使わない。

### 既定表示の写像(決定2 の肝)
未保存(ストアにキー無し)のツールの**表示状態**は annotations + trust から導く。実挙動(精緻化後の
evaluate)と一致させる:
- `trusted && readOnlyHint == true && openWorldHint != true` → 表示「常に許可(自動)」(runtime も proceed)。
- それ以外(未申告・readOnly false・open-world・untrusted・destructive 申告) → 表示「確認する」(runtime も confirm)。
ユーザーが画面3で明示選択したら、その decision がストアに入り表示・挙動とも上書きする。
※ 判定の正典は `evaluate` 一本。**設定画面は evaluate と同じ分岐を共有する純関数で「既定の見え方」を出す**。
実装ヒント: `ToolPermissionPolicy` に「未保存時の既定表示状態」を返す純関数を1つ足し、evaluate と readOnly/
openWorld/trusted 分岐を共有する(設定表示 = runtime 挙動を Kernel テストで固定)。「常に許可(自動)」は
ユーザーが明示保存した `.allow` と**表示上は区別**する(自動=annotations 由来・明示=ユーザー選択。前者は
サーバーが annotations を変えれば変わりうる旨を詳細画面で示す)。

### ランタイム確認シート(画面C・決定3)
- `.sheet` + `presentationDetents([.medium, .large])` + `presentationDragIndicator(.visible)`。
- `.medium`: ツール名(`server:tool` mono)+ 3 ボタン(1回だけ許可 / 常に許可 / 許可しない)。
- `.large`(引き出し): 引数 JSON 全文(整形・スクロール)+ 破壊警告 + 上記ボタン。
- 並行 tool call のキュー処理は現行踏襲(先頭1件を提示・応答で次へ)。外側 dismiss = deny も踏襲。
- `interactiveDismissDisabled` は付けない(スワイプ下げ = deny で宙吊り回避の現行挙動を保つ)。

## 実装スライス(案)

- **S1 (Kernel)**: `evaluate` に `openWorldHint != true` ガードと `trusted: Bool` を追加(緩和条件の精緻化・
  ベスプラ節)+ 未保存時の既定表示状態を返す純関数(`defaultDisplayDecision(annotations:trusted:)` 等)。
  evaluate と分岐を共有し設定表示 = runtime 挙動を保証。既存 evaluate 呼び出し側は trusted を渡す形へ更新
  (当面は接続=ユーザー追加なので trusted=true を注入)。Kernel テストで readOnly/openWorld/trusted/deny の
  全境界を固定。
- **S2 (Features)**: 設定に画面1〜3 を追加(ServerRegistry + 現在接続の tools/list + annotations + Store を配線)。
  SettingsSheet からの導線。type_body_length を睨んで view を分割。
- **S3 (Features)**: `ToolConfirmationDialog` を detent シートへ作り直し(既存キュー/deny 縮退は維持)。
- 各スライスは実装・テスト・Simulator E2E・make verify・docs/log・commit/push を一単位(完了条件)。
  S2/S3 は別ファイル中心なので並列可、S1 は先行(両者が依存)。

## 未決・要相談

- 一括メニュー(すべて確認/許可)の初手要否 —— まずは per-tool だけで出し、要望が出たら足す。
- ブロック(deny)ツールを LLM のツール一覧から**外す**か(claude.ai 「非表示」)、送るが実行段で弾くか。
  現行は「送って実行段で deny」。トークン節約と「モデルに存在を悟らせない」の観点では一覧から外す方が
  望ましいが、これはツール定義生成(Composer picker・queue 5)と絡むので別途。初手は現行踏襲。

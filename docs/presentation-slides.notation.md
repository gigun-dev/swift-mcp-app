# スライド notation(figmate / Figma Slides 用)

> 構成・原稿の正典は [`presentation-plan.md`](presentation-plan.md)。本ファイルは**描画の実体**。
> figmate の `commit` に**ルート1つずつ**渡す(1ルート = 1スライド)。
> 各ルートは 1920×1080 固定。Pattern A(`a:c j:c`)か Pattern B(`p:N a:s j:b`)を必ず明示。
>
> **未確定**: `<<学籍番号>>` / `<<氏名>>` は差し込み前に置換すること(S1)。

## 実装状況(2026-07-31・Figma Slides ファイル「Swift MCP Host」)

**S1 を除く 8 ルートを commit 済み**(全て figmate warnings ゼロ)。

> **学籍番号・氏名は本ファイルに書かない。** 本リポジトリは PUBLIC であり、
> 学籍番号を平文で commit するのは動画提出(講義内)とは露出の性質が違う。
> **実値は Figma ファイル内の S1 にのみ置く**(`read_node` で確認できる)。

> **第2版へ差し替え済み(2026-07-31)。** 構成改訂の理由は
> [`presentation-plan.md`](presentation-plan.md) §2 の改訂ブロックを正とする
> (①主役はアプリでサーバーは派生物 ②思想に寄りすぎて抽象的 ③MCP Apps の説明が必須)。
> **下記の notation 本文は第1版のまま**なので、内容は Figma の現物(nodeId)を正とする。

| スライド | 現 nodeId(中身) | 状態 |
| --- | --- | --- |
| S1 タイトル | `3:310` | ✅ 第1版のまま(学籍番号・氏名は Figma 側にのみ実値) |
| S2 **課題(1枚へ圧縮)** | `4:323` | ✅ 第2版 — 旧 S2/S3/S4 の思想3枚を統合 |
| S3 **つくったもの + MCP とは** | `4:338` | ✅ 第2版・**新規** |
| S4 **MCP Apps とは** | `4:353` | ✅ 第2版・**新規**(デモ理解の前提) |
| S5 **アーキテクチャ** | `4:370` | ✅ 第2版 — Workers + D1 明示・派生サーバーの位置づけ |
| S6 区切り札「第二部 デモ」 | `3:157` | ✅ 第1版のまま |
| S7 **工夫・苦労 + これから** | `4:398` | ✅ 第2版 — 旧 S8 を統合 |
| S-OVERLAY デモ枠 | `4:416` | ✅ 第2版 — **MCPHost 460×830 が主役 / 純正 300×560 はおまけ** |
| S Overlay Telop | `3:204` | ✅(テンプレート) |
| S Overlay Telop2 | `3:209` | ✅(テンプレート) |

**`edit replace` はスライドのグリッド位置を動かさない**ので、この差し替えで並び順は壊れていない
(S1 が 10枚目にある問題は別件・下記)。

### ⚠️ `edit replace` は**子ノード単体だと位置属性(left/top/right/bottom)を捨てる**

**2026-08-01 に踏んだ。** ページ番号を `n / 13` → `n / 12` へ振り直すため、
各スライドの**ページ番号テキストノードだけ**を `edit command:"replace"` した:

```
T "8 / 12" hug hug #cbd5e1 Inter 400 26 right:80 bottom:52
```

`right:` / `bottom:` を書いているのに**絶対配置が適用されず**、auto-layout の
流し込みに戻って本文直下(画面中央付近の左端)へ落ちた。同じ属性を**ルートごと**の
replace で書いたときは正しく効く(統合した 9枚目で確認済み)。
→ **位置属性はルート replace(または commit)でしか解釈されない。**

- **read_node は位置属性を出力しない。** よってルートを読み戻して replace する運用では
  `left:` / `right:` / `bottom:` が**毎回落ちる**。読み戻しで往復するなら、
  offset は**このファイル側に控えておいて手で足し直す**必要がある。
  本デッキの規約値: フッタ nav = `left:80 bottom:52` / ページ番号 = `right:80 bottom:52`。
- **復旧手順**(実際にやったこと): 壊した 9枚分について
  `read_node` → notation を取得 → nav とページ番号に offset を書き足す →
  **ルート単位で `edit replace`**。子だけを直そうとしない。
- ボツ案: Figma 上で手作業で position を戻す
  → 9枚 × 2要素 = 18回のドラッグ。ルート replace 9回のほうが確実で速い。

### ⚠️ スライドの並び順 — commit 順 = スライド順

figmate の `commit` は**ルートを1枚ずつグリッド末尾に追加する**。したがって
**commit した順序がそのままスライドの並び順になる**。`edit replace` は
「SLIDE はグリッド位置に留まり子だけ差し替わる」仕様なので、**並べ替え手段は無い**。

**今回踏んだ**: 学籍番号待ちで S1 を最後に commit した結果、タイトルが **10枚目**に入った。
S1 以外は正しい相対順(S2→S3→S4→S5→S6→S8→テンプレート3枚)だったため、
**Figma 上で10枚目を1番目へドラッグして是正**した。

- ボツ案: 全スライドの中身を1つずつずらす 10 回の `edit replace`
  → ドラッグ1回より明確に危険(途中で失敗すると内容が混ざる)。
- **当面の規律**: **発表順に commit する**。値が未確定のスライドがあっても、
  プレースホルダで先に枠を commit しておき、後から `edit replace` で中身だけ埋める
  (replace は位置を動かさないので順序が壊れない)。
- **figmate 側の恒久対策は figmate リポジトリに起票済み**:
  `gigun-dev/figmate` の `docs/slide-ordering-proposal.md`
  (`edit` に `command:"move"`(nodeId + index)を足す提案)。
  規律で守る設計は agent 相手だと破綻する、というのが今回の教訓。

### 実装時の是正(本ファイルの記載との差分)

初稿は本文コンテンツ系スライドのルートを **Pattern B(`p:96 a:s j:b`)** で書いていたが、
commit 後の目視で **画面中央に大きな死に空間**が出た(`j:b` が2〜3個の子を上下端へ
押しやり、内容量 ≒ 600px に対し可用高 888px の差分がすべて中間に溜まる)。

→ **`p:96 a:s j:c gap:56`(垂直中央寄せ)へ全面変更**し、`Top` ラッパーは
不要なものを外して子を直接ルートへ並べた。以下のスライドが対象:
**S2 / S3 / S4 / S5 / S8**。S6 は元から Pattern A(`a:c j:c`)なので変更なし。

- ボツ案①: 子に `fill` 高を与えてカードを引き伸ばす
  → カード高 500px に本文2行だと中身が空洞に見える。中央寄せの方が素直。
- ボツ案②: 本文を足して高さを埋める
  → 5分の尺で読ませる文字数ではない。スライドは骨だけ、という方針に反する。

**以後の再 commit は、下記 notation ではなく上記 nodeId の現物を正とする**
(`read_node` で読み戻せる)。下記 notation の root 行は初稿のままなので、
再利用するときは `j:b` → `j:c gap:56` に読み替えること。

---

## デザイントークン(全スライド共通)

| 役割 | 値 | 用途 |
| --- | --- | --- |
| 背景 | `#0b1220` | 全スライド。埋め込む Simulator 画面(明るい)を際立たせる |
| サーフェス | `#151d31` | カード地 |
| サーフェス強調 | `#1e2540` | 結論ブロック・ハイライトカード |
| 本文 | `#f8fafc` | 見出し・強調 |
| 副文 | `#94a3b8` | 補足・キャプション |
| アクセントA(技術) | `#818cf8` | MCP・プロトコル・アプリ名 |
| アクセントB(人・予定) | `#fb923c` | 課題・感情・結論の刺し色 |

和文は `"Noto Sans JP"`、欧文・記号のみの行は `Inter`。
文字サイズは figmate の Slides ラダー準拠(Title 96 / H1 60 / H2 48 / H3 36 / Body1 36 /
Body2 30 / Body3 24 / Note 20)。**本文の下限は 30**。

---

## S1 タイトル(0:00–0:15)

```
V "S1 Title" 1920 1080 #0b1220 a:c j:c gap:40
  T "MCPHost" hug hug #818cf8 Inter 700 60
  T "ひとりのカレンダーを、\nみんなの道具へ" hug hug #f8fafc "Noto Sans JP" 700 96 ta:c
  T "AI エージェント × 自作 CalDAV サーバー" hug hug #94a3b8 "Noto Sans JP" 400 36
  H "Meta" hug hug a:c gap:24
    H "Platform" hug hug #818cf8 a:c j:c p:16,32 br:999
      T "iOS + Swift" hug hug #0b1220 Inter 700 30
    H "Id" hug hug #151d31 a:c j:c p:16,32 br:999
      T "<<学籍番号>>   <<氏名>>" hug hug #f8fafc "Noto Sans JP" 400 30
  T "プログラミング実践II 最終課題" hug hug #64748b "Noto Sans JP" 400 20
```

---

## S2 課題提起(0:15–0:50)

```
V "S2 Problem" 1920 1080 #0b1220 p:96 a:s j:b
  V "Top" fill hug a:s gap:48
    T "「この日どうする?」が、なぜ重いのか" hug hug #f8fafc "Noto Sans JP" 700 48
    H "Beats" fill hug a:c gap:32
      V "B1" fill hug #151d31 a:s j:s gap:16 p:40 br:20
        T "連絡先は増え続ける" fill hug #f8fafc "Noto Sans JP" 700 36
        T "SNS・チャット・DM で\nつながる相手が増える" fill hug #94a3b8 "Noto Sans JP" 400 30
      V "B2" fill hug #151d31 a:s j:s gap:16 p:40 br:20
        T "同時多発的に、切れ目なく" fill hug #f8fafc "Noto Sans JP" 700 36
        T "タイムラグなしで\nやりとりが走る" fill hug #94a3b8 "Noto Sans JP" 400 30
      V "B3" fill hug #151d31 a:s j:s gap:16 p:40 br:20
        T "でも一日は 24時間のまま" fill hug #f8fafc "Noto Sans JP" 700 36
        T "調整の難易度だけが\n上がっていく" fill hug #94a3b8 "Noto Sans JP" 400 30
  V "Conclusion" fill hug #1e2540 a:c j:c gap:20 p:48 br:24
    T "調整コスト  >  誘いたい気持ち" hug hug #fb923c "Noto Sans JP" 700 60
    T "→ コストを払ってもいい相手としか、予定を立てなくなる" hug hug #f8fafc "Noto Sans JP" 400 36
```

---

## S3 なぜ解けないのか(0:50–1:20)

```
V "S3 Why" 1920 1080 #0b1220 p:96 a:s j:b
  V "Top" fill hug a:s gap:24
    T "カレンダーは、ほとんど「1人用の道具」" hug hug #f8fafc "Noto Sans JP" 700 48
    T "予定は 頭の中・口約束・DM・複数のカレンダー に散らばり、追加も管理も手動" fill hug #94a3b8 "Noto Sans JP" 400 30
  H "Existing" fill hug a:c gap:32
    V "E1" fill hug #151d31 a:s j:s gap:16 p:40 br:20
      T "iCloud カレンダー共有" fill hug #f8fafc "Noto Sans JP" 700 36
      T "参加につまずきやすく\n難易度が高い" fill hug #94a3b8 "Noto Sans JP" 400 30
    V "E2" fill hug #151d31 a:s j:s gap:16 p:40 br:20
      T "ICS 照会カレンダー" fill hug #f8fafc "Noto Sans JP" 700 36
      T "読み取り専用で\n更新頻度も低い" fill hug #94a3b8 "Noto Sans JP" 400 30
    V "E3" fill hug #151d31 a:s j:s gap:16 p:40 br:20
      T "TimeTree" fill hug #f8fafc "Noto Sans JP" 700 36
      T "iOS カレンダーへ逆に出せない\n開発者 API も廃止" fill hug #94a3b8 "Noto Sans JP" 400 30
  V "Conclusion" fill hug #1e2540 a:c j:c p:40 br:24
    T "新しいアプリを増やすほど、分断も増えていく" hug hug #fb923c "Noto Sans JP" 700 48
```

---

## S4 AI だけでは解けない(1:20–1:45)

```
V "S4 Gap" 1920 1080 #0b1220 p:96 a:s j:b
  V "Top" fill hug a:s gap:48
    T "AI に任せれば済む、とはならない" hug hug #f8fafc "Noto Sans JP" 700 48
    H "Split" fill hug a:c gap:32
      V "Server" fill hug #151d31 a:s j:s gap:16 p:48 br:20
        T "エージェント" fill hug #818cf8 "Noto Sans JP" 700 36
        T "サーバー側で動く" fill hug #f8fafc "Noto Sans JP" 400 30
        T "毎朝リマインドも、メールからの\n予定化も、サーバーだからできる" fill hug #94a3b8 "Noto Sans JP" 400 24
      V "Wall" hug hug #1e2540 a:c j:c p:32 br:999
        T "✕" hug hug #fb923c Inter 700 60
      V "Device" fill hug #151d31 a:s j:s gap:16 p:48 br:20
        T "iOS の予定(EventKit)" fill hug #fb923c "Noto Sans JP" 700 36
        T "端末の中に閉じている" fill hug #f8fafc "Noto Sans JP" 400 30
        T "サーバーから参照できない。\nバックグラウンド実行も保証がない" fill hug #94a3b8 "Noto Sans JP" 400 24
  V "Conclusion" fill hug #1e2540 a:c j:c p:48 br:24
    T "AI と「データを集約する開かれた基盤」は、セットでなければ意味がない" hug hug #f8fafc "Noto Sans JP" 700 48
```

---

## S5 方針・概要・仕様(1:45–2:05)

> **講義必須項目「開発プラットフォーム」をチップで明示**(S1 と二重に出して取りこぼしを防ぐ)。

```
V "S5 Approach" 1920 1080 #0b1220 p:96 a:s j:b
  V "Top" fill hug a:s gap:40
    T "方針と、つくったもの" hug hug #f8fafc "Noto Sans JP" 700 48
    H "Policies" fill hug a:c gap:24
      V "P1" fill hug #151d31 a:s j:s gap:12 p:36 br:20
        T "1" hug hug #818cf8 Inter 700 36
        T "開かれたプロトコルで作る" fill hug #f8fafc "Noto Sans JP" 700 30
        T "ベンダーロックインしない" fill hug #94a3b8 "Noto Sans JP" 400 24
      V "P2" fill hug #151d31 a:s j:s gap:12 p:36 br:20
        T "2" hug hug #818cf8 Inter 700 36
        T "既存の習慣を壊さない" fill hug #f8fafc "Noto Sans JP" 700 30
        T "予定=純正カレンダー\nタスク=純正リマインダー" fill hug #94a3b8 "Noto Sans JP" 400 24
      V "P3" fill hug #151d31 a:s j:s gap:12 p:36 br:20
        T "3" hug hug #818cf8 Inter 700 36
        T "同じデータに 2つの口" fill hug #f8fafc "Noto Sans JP" 700 30
        T "人間用=CalDAV\nエージェント用=MCP" fill hug #94a3b8 "Noto Sans JP" 400 24
  V "Spec" fill hug #1e2540 a:s j:s gap:24 p:48 br:24
    H "SpecHead" fill hug a:c gap:24
      T "MCPHost — iOS 汎用 MCP Apps ホスト" hug hug #f8fafc "Noto Sans JP" 700 36
      H "Platform" hug hug #818cf8 a:c j:c p:12,28 br:999
        T "開発プラットフォーム: iOS + Swift" hug hug #0b1220 "Noto Sans JP" 700 30
    T "iOS 17+ / SwiftUI ・ swift-sdk HTTPClientTransport ・ OAuth 2.1 フルフロー(DCR → authorize → token)・ LLM tool-use ループ(BYOK)" fill hug #94a3b8 "Noto Sans JP" 400 30
```

---

## S6 区切り札「第二部 デモ」(2:05–2:15 / 10秒)

> 講義仕様の**二部構成をグレーダーに明示する**ための札。
> **エミュレータ使用の断り(「理由を明示」要件)もここで回収する。**

```
V "S6 Demo Divider" 1920 1080 #0b1220 a:c j:c gap:32
  T "第二部" hug hug #818cf8 "Noto Sans JP" 700 60
  T "デモ" hug hug #f8fafc "Noto Sans JP" 700 96
  V "Note" hug hug #151d31 a:c j:c gap:12 p:32,48 br:20
    T "iOS Simulator を3画面並べて収録しています" hug hug #f8fafc "Noto Sans JP" 700 30
    T "理由: 操作した画面と、純正カレンダー・リマインダーの変化を同時に見せるため" hug hug #94a3b8 "Noto Sans JP" 400 24
```

---

## S-OVERLAY デモ注釈オーバーレイ(2:15–4:40 / 145秒)

> **これはスライドとして流すものではなく、デモ映像に重ねるテンプレート。**
> 上段=3画面の配置枠(収録の位置合わせ基準)、下段=注釈バンド。
> **講義必須項目③「詳細な説明」と④「工夫・苦労」はここに載せる**(統合構成)。
>
> 動画編集では、下段バンドのテキストだけをデモの進行に合わせて差し替える。

```
V "S Overlay" 1920 1080 #0b1220 p:56 a:s j:b
  H "Screens" fill hug a:c j:c gap:40
    V "Col1" hug hug a:c j:s gap:12
      V "Slot1" 372 760 #000000 a:c j:c br:32 s:#818cf8 sw:3
        T "MCPHost" hug hug #334155 "Noto Sans JP" 400 24
      T "操作するのはここだけ" hug hug #818cf8 "Noto Sans JP" 700 30
    V "Col2" hug hug a:c j:s gap:12
      V "Slot2" 372 760 #000000 a:c j:c br:32 s:#1e2540 sw:2
        T "純正カレンダー" hug hug #334155 "Noto Sans JP" 400 24
      T "何もしていない" hug hug #fb923c "Noto Sans JP" 700 30
    V "Col3" hug hug a:c j:s gap:12
      V "Slot3" 372 760 #000000 a:c j:c br:32 s:#1e2540 sw:2
        T "純正リマインダー" hug hug #334155 "Noto Sans JP" 400 24
      T "何もしていない" hug hug #fb923c "Noto Sans JP" 700 30
  H "Band" fill hug #151d31 a:c j:s gap:32 p:28,40 br:20
    T "3" hug hug #818cf8 Inter 700 36
    T "WKWebView サンドボックスで ui:// の HTML カードを描画する" fill hug #f8fafc "Noto Sans JP" 400 36
```

### 下段バンドの差し替え台本(講義必須項目③「詳細な説明」)

デモの進行に合わせてバンドのテキストを差し替える。番号は `#818cf8` の Inter 700 36。

| # | バンド本文 | 出すタイミング |
| --- | --- | --- |
| — | `iPhone(MCPHost) ⇄ MCP ⇄ caldav(Cloudflare Workers / D1)` | 起動・コネクタ一覧 |
| — | `TDR Wait Times など他の MCP サーバーも同列に接続できる(汎用ホスト)` | コネクタ一覧を見せている間 |
| 1 | `LLM がツールを呼ぶ` | 依頼文を送った直後 |
| 2 | `ツール結果が ui:// の HTML カードを指す` | カードが出る直前 |
| 3 | `WKWebView サンドボックスで描画する` | カード描画の瞬間 |
| 4 | `postMessage ⇄ JSON-RPC でカード内操作をツール呼び出しへ往復` | カード内を操作するとき |
| — | `caldav ⇄ CalDAV ⇄ iOS 純正カレンダー / リマインダー` | **ハイライト(右2画面に現れる瞬間)** |

### 工夫・苦労テロップ(講義必須項目④)

**カード描画の瞬間(バンド #3)に、画面中央へ大きく被せる。** 注釈バンドだけだと
読み落とされるため、ここだけ別レイヤーで強く出す。

```
V "S Overlay Telop" 1920 1080 #0b1220cc a:c j:c
  V "Telop" 1400 hug #1e2540 a:c j:c gap:20 p:56 br:28
    T "工夫した点・苦労した点" hug hug #818cf8 "Noto Sans JP" 700 30
    T "iOS ネイティブの汎用 MCP Apps ホストは、前例がほぼ無い" hug hug #fb923c "Noto Sans JP" 700 48 ta:c
    T "公式のホスト SDK は TypeScript 版しか存在しない。\nホスト側プロトコルを Swift で実装すること自体が、このアプリの本体になった。" hug hug #f8fafc "Noto Sans JP" 400 30 ta:c
```

補助テロップ(尺に余裕があれば、デモ後半で 5秒ずつ):

```
V "S Overlay Telop2" 1920 1080 #0b1220cc a:c j:c
  H "Cards" 1560 hug a:c j:c gap:24
    V "C1" fill hug #1e2540 a:s j:s gap:12 p:36 br:20
      T "OAuth 2.1 フルフロー" fill hug #f8fafc "Noto Sans JP" 700 30
      T "DCR → authorize → token を\nASWebAuthenticationSession で" fill hug #94a3b8 "Noto Sans JP" 400 24
    V "C2" fill hug #1e2540 a:s j:s gap:12 p:36 br:20
      T "サンドボックスとブリッジ" fill hug #f8fafc "Noto Sans JP" 700 30
      T "WKWebView 隔離と\nJSON-RPC 往復の設計" fill hug #94a3b8 "Noto Sans JP" 400 24
    V "C3" fill hug #1e2540 a:s j:s gap:12 p:36 br:20
      T "「判断ゲート」方式" fill hug #f8fafc "Noto Sans JP" 700 30
      T "カード描画が通らなければ\nネイティブ描画へ撤退する計画で着手" fill hug #94a3b8 "Noto Sans JP" 400 24
```

---

## S8 これから + 題目の回収(4:45–5:00)

```
V "S8 Next" 1920 1080 #0b1220 p:96 a:s j:b
  V "Top" fill hug a:s gap:40
    T "今日お見せしたのは、ここまで" hug hug #94a3b8 "Noto Sans JP" 400 36
    T "ひとりのカレンダーを、開かれた基盤に載せる" hug hug #f8fafc "Noto Sans JP" 700 60
    H "Roadmap" fill hug a:c gap:24
      V "R1" fill hug #151d31 a:s j:s gap:12 p:36 br:20
        T "カレンダー共有" fill hug #f8fafc "Noto Sans JP" 700 36
        T "コレクション単位で分け合う" fill hug #94a3b8 "Noto Sans JP" 400 24
      V "R2" fill hug #151d31 a:s j:s gap:12 p:36 br:20
        T "予定の招待" fill hug #f8fafc "Noto Sans JP" 700 36
        T "出席者と出欠のやりとり" fill hug #94a3b8 "Noto Sans JP" 400 24
      V "R3" fill hug #151d31 a:s j:s gap:12 p:36 br:20
        T "空き時間の照会" fill hug #f8fafc "Noto Sans JP" 700 36
        T "「いつ空いてる?」を自動で" fill hug #94a3b8 "Noto Sans JP" 400 24
  V "Closing" fill hug #1e2540 a:c j:c gap:16 p:48 br:24
    T "「みんなの道具へ」は、その次。" hug hug #fb923c "Noto Sans JP" 700 60
    T "もっと気軽に誘えるようにすること。それがこのアプリの目的地です。" hug hug #f8fafc "Noto Sans JP" 400 36
```

---

## commit 手順

1. Figma アプリで **figmate プラグインを起動**(`ws://127.0.0.1:4711` が立つ)。
2. Claude Code で `/mcp` から figmate を再接続。
3. `validate_notation` で各ルートを検証 → `commit` を**1ルートずつ**実行。
4. **commit のレスポンスの `warnings` を必ず読む**(overflow / lopsided container を検出する)。
   問題があれば `edit` の `command:"replace"` で該当 nodeId を差し替える。

### commit 前の未処理

- [x] ~~S1 の `<<学籍番号>>` / `<<氏名>>` を実値へ置換~~ ✅ Figma 側で反映済み(本ファイルは非記載)
- [x] ~~和文の実測幅を確認~~ ✅ 全ルート commit で figmate warnings ゼロ・目視でも overflow なし
- [ ] `S Overlay Telop` / `S Overlay Telop2` の背景 `#0b1220cc`(80% 不透明)は
      **動画に重ねる前提**。Figma 上では下が透けないので、書き出し時に背景を透過にするか、
      編集ソフト側で不透明度を再設定する

### commit する順番(全 7 + 3)

**スライドとして流すもの(7枚)**: S1 → S2 → S3 → S4 → S5 → S6 → S8
**動画編集用のテンプレート(3枚)**: S-OVERLAY / S Overlay Telop / S Overlay Telop2

テンプレート3枚は本編には出さない。Figma Slides 上では末尾にまとめて置き、
書き出し時に本編から外す(または別ページへ退避)。

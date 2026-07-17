# 設計 05: 場所・会議・URL(vevent/vtodo の入力体験と feasibility)

> **位置づけ**: 恒久ドキュメント(設計の正典)。2026-07-17 のユーザー問題提起
> 「vevent/vtodo どちらでも場所の入力体験が弱い」から出た一連の発見・裁定を記録する。
> 更新ルールは 04 と同じ(計画は消さない・変化は `> 日付 更新:` を積層)。
> 実装タスクの分解はセッションタスク C0〜C8 / H-a,b(§6)。契約の正は caldav 側。

## 0. 問題提起(2026-07-17・ユーザー)

Apple(iOS カレンダー/リマインダー)の体験を基準にすると:

- **vtodo の場所** = 「指定した場所の出発時 or 到着時に通知する」もの。
  選択肢: 現在地 / 自宅 / 乗車時 / 降車時 / カスタム(地図から選択)。
- **vevent の場所** = secondary input box で「場所 **or** 会議」を受け付ける。
  - **URL との使い分け**: URL はミーティングのお知らせ(メール等)に飛ぶ参照リンク。
    「会議」は Google Meet 等に飛ぶ Join リンク。
  - **会議は自由度が高い**: 基本はビデオ通話として解釈するが、x.com なども指定できる
    (= x.com でビデオ通話する、と解釈される。実機で「参加」ボタンが出る)。
  - 「場所または会議」input に focus するとセミモーダルが立ち上がる
    (検索欄 / 現在地 / ビデオ通話 provider / 履歴 / キーボード候補に既知の場所)。

これは1つの入力欄に見えて、**意味的には3スロット**(場所 / 会議 / 参照 URL)が
畳み込まれている。この意味モデルの把握が本設計の核心。

## 1. 実データ decode(caldav 本番 D1 の生 ICS・2026-07-17 採取)

ユーザーが iOS client 経由で caldav に実例を保存し、D1 を直接読んで裏取りした。
**caldav は生 ICS ストアなので Apple の拡張プロパティをそのまま round-trip できている**
(規格逸脱なし)。以下が「Apple の魔法」のワイヤ上の正体。

### 1-a. vtodo「自宅に到着時に通知」= proximity VALARM

```
BEGIN:VALARM
ACTION:DISPLAY
TRIGGER;VALUE=DATE-TIME:19760401T005545Z      ← Apple の番兵日付(時刻トリガ無しの印)
X-APPLE-PROXIMITY:ARRIVE                       ← 到着(DEPART = 出発)
X-APPLE-STRUCTURED-LOCATION;VALUE=URI;X-APPLE-RADIUS=100;X-APPLE-REFERENCEFRAME=1;
 X-TITLE=福登の自宅:geo:35.017639,136.954547   ← タイトル + geo 座標 + 半径
END:VALARM
```

geofence リマインダーの実体は「番兵 TRIGGER + X-APPLE-PROXIMITY +
X-APPLE-STRUCTURED-LOCATION(geo URI)」の VALARM。新プロパティ不要。

### 1-b. vevent の場所 = LOCATION(表示テキスト)+ X-APPLE-STRUCTURED-LOCATION(構造化)

```
LOCATION:岐阜大学\n501-1112\n岐阜県 岐阜市\n柳戸1-1\n日本
X-APPLE-STRUCTURED-LOCATION;VALUE=URI;X-ADDRESS=...;X-APPLE-RADIUS=100;
 X-TITLE=岐阜大学:geo:35.463012,136.737202
```

Apple Maps 由来の候補には `X-APPLE-MAPKIT-HANDLE`(不透明 blob)も付くが、
read には X-TITLE / X-ADDRESS / geo だけで足りる(MAPKIT-HANDLE は温存 pass-through)。

### 1-c. 会議 vs 参照 URL(最重要の発見)— 本物の招待(paiza 面談)の実例

```
URL;VALUE=URI:message:%3C...amazonses.com%3E?c=...   ← URL = message: スキーム
                                                        (お知らせメールを開く参照リンク!)
DESCRIPTION:...----( ビデオ通話 )----\n
 https://meet.google.com/xpk-yooe-eev\n---===---      ← 会議(Join)= DESCRIPTION 内の
                                                        「ビデオ通話」区切りブロック
```

**Apple は会議のために新プロパティ(RFC 7986 CONFERENCE 等)を使っていない。**
- 単独の会議リンクは `URL` に直入れ(`URL;VALUE=URI:https://meet.google.com/abc` の実例あり)。
- 参照 URL と会議が併存するときは、URL=参照(message: 等)・会議=DESCRIPTION の
  区切りブロック、という**author 規約 + 読み取りヒューリスティック**で実現している。
- caldav 作成の `URL:x.com` も実機で「参加」(ビデオ通話)として解釈された(ユーザー実機
  スクショ)= 読み手が URL を Join として開くだけなので、任意ドメインが自然に会議になる。

> **裁定(2026-07-17)**: 当初「会議を参照 URL と別枠にするには CONFERENCE プロパティ新設の
> サーバー作業が要る」と見積もったが、実データにより**撤回**。Apple 自身がプロパティを増やさず
> 規約+走査で実現している以上、caldav も**スキーマ変更ゼロ**で一致できる。
> = ボツ案「CONFERENCE 新設」は財産として残す(将来 RFC 7986 準拠クライアントとの相互運用が
> 必要になったら再訪)。

## 2. 意味モデル(3スロット)

| スロット | 実体(ICS) | 読み取り時の挙動 |
|---|---|---|
| **場所** | LOCATION(TEXT)+ X-APPLE-STRUCTURED-LOCATION(X-TITLE/X-ADDRESS/geo/半径) | 📍 タイトル表示。vtodo では proximity VALARM で到着/出発通知 |
| **会議** | URL 直入れ or DESCRIPTION「ビデオ通話」ブロック(併存時) | 🎥「参加」= URL を Join として開く。任意ドメイン可(x.com も可) |
| **参照 URL** | URL(message: スキーム等も生値のまま) | 🔗 ただのリンク(Join ではない) |

読み取りは `url` / `description` / structured-location を走査した**派生フィールド**
(`conference` / `structuredLocation` / `proximityAlarm`)を DTO に足すだけで表現できる。

## 3. Feasibility(サンドボックス制約と代替戦略)

カードは**サンドボックス WKWebView** で動く。本アプリの実装(AppCardView.swift
`compileBlockAllRuleList`)は ContentRuleList `".*" block` の**全通信遮断** +
baseURL nil(opaque origin)+ 初回以外 navigation 封じ。この前提で:

| Apple の機能 | カード単体 | 代替 | 実現層 |
|---|---|---|---|
| 場所テキスト入力 | ✅ | — | カード |
| 会議 = 任意 URL を Join 解釈 | ✅ | — | カード(描画)+ 規約(書き) |
| 履歴(過去に使った場所) | ❌(端末の履歴は読めない) | **ユーザー自身の過去 structured-location を caldav が集約**(「福登の自宅」は既にデータにある) | caldav 新ツール(C5) |
| 「岐阜大学」と入力して候補から選ぶ | ❌(外部 API 不可) | **caldav geocode ツール**(Worker がジオコーディング API を叩く — Worker はサンドボックス外) | caldav 新ツール(C6) |
| 候補を地図で見て選ぶ | ❌(タイル fetch 遮断) | (a) **Worker 静的地図サムネを data URI で同梱**(カードは `<img src="data:...">` を描くだけ・実ネットワークゼロ) / (b) ホストの宣言型網許可 + ライブタイル | (a) caldav / (b) ホスト H-a |
| 地図をグリグリして任意地点にピン | ❌ | (b) のみ | ホスト H-a |
| **現在地** | ❌(navigator.geolocation 未配線) | CLLocationManager ブリッジ(H-b) | ホスト(パーク) |
| 乗車時/降車時 | ❌(端末センサー専用) | 代替なし | パーク |
| インストール済み provider 検出(FaceTime/X) | ❌ | provider チップは静的リスト+任意 URL 入力で代替 | カード |

**要点: 「Apple が端末サービスから得る知能」の大半は「caldav Worker のサーバー側能力」で
代替できる。** カードは入力と描画、知能は Worker、という分担ならサンドボックスも
ホスト中立性(ビジョン2)も無傷。本アプリの thesis(LLM オーケストレーション)とも整合
— 自然言語の場所指定はチャット(LLM が create-* を呼ぶ)が既に担っている。

### 3-a. 地図の (a)/(b) は C6 着手時に最終決定(留保・2026-07-17 fable 裁定)

- **(a) 静的サムネ**: サンドボックス無傷だが、コストは Worker 側に移る(静的地図 API の
  選定・利用規約・キー管理・キャッシュ)。ContentRuleList が `data:` URI を巻き込まないかの
  実機確認も必要(巻き込むなら遮断ルールを `https?://` スコープに直す — data: はローカルなので
  実ネットワークは依然ゼロ)。
- **(b) 宣言型ネットワーク許可 + ライブタイル**: ContentRuleList の変更自体は
  `ignore-previous-rules` を数行足すだけで**技術的には簡単**(当初「工数大」と見積もったのは
  誤り・撤回)。難しさはメカニクスでなく**権限モデルの設計判断**(何を封じ何を宣言ベースで
  許すか)。caldav ドメインのハードコードは中立性を壊すため不可 — やるなら
  「**カードが必要ドメインを宣言 → ホストが allowlist 化(+ユーザー同意)**」の汎用機構
  (H-a)として。
- **(b) の格上げ(fable 裁定)**: H-a は「地図のための妥協」ではなく**ホストの正当な
  ロードマップ候補**。世の MCP Apps カードは自己完結バンドルばかりではなく、外部 CDN
  参照カードは必ず来る。「全遮断で動くカードだけ動く」ホストは汎用ホストとして未完成で、
  宣言型ネットワーク権限はいずれ避けられない。地図はその最初の実利用例になれる。
  権限モデルは thesis(Swift で MCP Apps ホストを実装)の中で一番設計密度が高く語れる部分。
- ただし**順序は変えない**: (a) で「候補を地図で確認して選ぶ」体験が十分か先に検証できる。
  十分なら (b) は不要かもしれず、不十分なら (b) の要件が実体験ベースで確定する。

## 4. 関連する同日裁定(inline モデル・作成フロー)

詳細は設計エージェントの調査報告(会話ログ 2026-07-17)と docs/design/mocks/。
ここには結論だけ再掲する:

- **inline = 境界の効いたプレビュー / fullscreen = 全件 + 作成**。
  - 「すべて表示」ボタンと動的畳みは**廃止**(⤢ と役割重複)。`computeInlineFit` 純関数は
    「N 件でも端末次第で溢れる」対策の安全クランプとして再利用(DOM 畳み機構だけ捨てる)。
  - フッタに「他 n 件 — 全画面で表示」の要約行(タップ= ⤢ と同じ昇格)。
  - 完了残骸は**カード lifecycle スコープ**(ユーザー裁定)+ 約5秒の undo 猶予後に退場で
    有界化(無制限蓄積が inline クリップの主因だった)。
  - 削除ゴースト(破線の「点々」)は**廃止**(ユーザー裁定:「基本削除しない(完了にする)し、
    削除したものは見せなくていい」)。自分削除=即フェード。外部同期由来の削除の扱い
    (黙って消えると混乱しうる)だけ実装時に決める。
- **vevent 作成 = fullscreen 詳細フォーム**(inline quick-add は DTSTART 必須のため API 契約上
  不成立 — 業界も NL パーサ(=本アプリではチャットの役割)かフル画面フォーム)。
  予定/リマインダーのセグメント切替は**片方向**(event フォームから todo へは切替可・逆は無し。
  iOS/Fantastical に前例)。
- **vtodo 作成 = 既存 quick-add 維持**(ユーザー裁定 2026-07-17: 段階的開示(モック状態2)は
  不要。quick-add は VTODO では業界標準で正しい)。

## 5. vevent「場所または会議」入力の設計(C4)

Apple のセミモーダル(画像 IMG_8132)に寄せた、カード内オーバーレイ(WKWebView 内の
CSS モーダルなのでサンドボックス無関係):

```
[場所または会議 を focus]
  ┌─────────────────────────────┐
  │ 🔍 場所またはビデオ通話を入力          │ ← 1入力欄(多相)
  ├─────────────────────────────┤
  │ ビデオ通話                            │
  │   [Meet] [Zoom] [FaceTime] [その他URL] │ ← provider チップ(静的)+任意 URL=Join
  ├─────────────────────────────┤
  │ 既知の場所(C5)                       │
  │   📍 福登の自宅(過去の VALARM から)   │ ← caldav が集約した structured-location
  │   📍 岐阜大学                          │
  ├─────────────────────────────┤
  │ 検索候補(C6・入力時)                 │
  │   📍 岐阜大学 — 岐阜県岐阜市柳戸1-1 [地図サムネ] │
  └─────────────────────────────┘
```

- 「現在地」行は置かない(H-b 未実装)。将来 H-b が来たら足す。
- vtodo 側の到着/出発は、既知の場所/検索候補で座標が取れれば proximity VALARM を書けるので
  同じピッカーを共用できる(到着/出発のトグルを添える)。

## 6. 実装タスク分解(2026-07-17 合意)

依存順: **D1(本書)→ C0 → C1+C2 → C3+C4+C5(+C8) → C6+C7** / H-a,b は将来枠。

| ID | 内容 | 層 |
|---|---|---|
| C0 | inline 基本修理: (a)完了残骸の有界化 (b)プレビュー化(すべて表示廃止) (c)削除ゴースト廃止 (d)vtodo quick-add 維持 | caldav カード |
| C1 | DTO 拡張(read): conference / structuredLocation / proximityAlarm 派生フィールド(スキーマ変更ゼロ) | caldav usecase |
| C2 | カード描画(read): agenda に 📍/🎥参加/🔗、todos に 📍「〜に到着時」バッジ | caldav カード |
| C3 | vevent fullscreen 作成フォーム + 予定/リマインダーセグメント(片方向) | caldav カード |
| C4 | 場所/会議セミモーダル(§5) | caldav カード |
| C5 | 既知の場所ツール(過去 structured-location 集約) | caldav ツール |
| C6 | geocode ツール(地名→座標候補。API 規約/キー/キャッシュ選定込み) | caldav ツール |
| C7 | 候補の地図確認 — (a)静的サムネ/(b)ライブタイル を C6 着手時に決定(§3-a) | caldav or ホスト |
| C8 | 書き込み author 規約(URL=参照・会議=DESCRIPTION ブロック・proximity VALARM 書き出し)— C3〜C5 に同梱 | caldav usecase |
| H-a | 宣言型ネットワーク権限(カードがドメイン宣言 → allowlist +同意)。thesis 主戦場・将来枠 | ホスト |
| H-b | geolocation ブリッジ(CLLocationManager → navigator.geolocation)。将来枠 | ホスト |

**C1+C2 を write(C3〜)より先に置く理由**: 実データ(§1)が既に本番 D1 にあるので、
read だけで「カードに 📍 と参加ボタンが生える」成果が最安で出る。

## 7. ボツ案(財産)

- **CONFERENCE プロパティ(RFC 7986)新設** — Apple 自身が使っていない(§1-c)。規約+走査で足りる。
- **カード内 NL パーサ**(Fantastical 型)— NL 解釈はチャット(LLM)の役割。二重実装。
- **inline quick-add for vevent** — DTSTART 必須で API 契約上不成立。
- **caldav タイルドメインのホスト側ハードコード** — 中立性(ビジョン2)を壊す。やるなら H-a。
- **「サンドボックス緩和は工数大」という当初見積り** — ContentRuleList の変更自体は数行。
  難しいのは権限モデルの設計判断(撤回の経緯は §3-a)。
- **地図なしでは場所選択は無理、という当初判定** — geocode(Worker)+リスト型ピッカーで
  「岐阜大学と入力して選ぶ」は地図なしで成立(候補の視覚確認だけ (a)/(b) の論点として残る)。
- **vtodo 作成の段階的開示(モック create-todo-quickadd.html 状態2)** — ユーザー裁定で不要。

# 設計 04: displayMode ネゴシエーションとカード高さ(背の高いインラインカードの到達性問題)

> 2026-07-16 起票。P3 実機検証で表面化した「todos が多いとカードが画面高を超え、カード上端の
> 『完了』ボタン・下端の『+』FAB に同時に到達できない」問題の恒久設計。ユーザー合意済みの方針
> (inline は maxHeight 制約 + `ui/request-display-mode` で fullscreen 昇格 + sticky/畳みは caldav 側)を
> 正式に固める。docs/design/01〜03 と同じ書式(決定・根拠・ボツ案・一次資料への出典行)。
> 実装前の設計文書であり、実装で判明した事実は「> 日付 更新:」で積層する。
>
> 一次資料(すべてローカルで確認済み。行番号は 2026-07-16 時点のチェックアウト):
> - ext-apps 規範仕様: ~/ghq/github.com/modelcontextprotocol/ext-apps/specification/2026-01-26/apps.mdx
>   :557-616(HostContext フィールドと例 — `"containerDimensions": { "width": 400, "maxHeight": 600 }`)、
>   :671-733(containerDimensions の意味論: fixed/flexible、View 側の推奨 CSS、
>   :718「flexible のときホストは size-changed を **MUST listen** し iframe 寸法を更新」、
>   :733 SDK は autoResize 既定 ON で ResizeObserver から自動送信)、
>   :740-745(McpUiDisplayMode = inline | fullscreen | pip)、
>   :749-787(ネゴシエーション規則。:751 View は appCapabilities.availableDisplayModes を宣言、
>   :768 Host は HostContext.availableDisplayModes を宣言、:772 モード変更要求は
>   `ui/request-display-mode`、:776「Host はモード変化を `ui/notifications/host-context-changed` の
>   displayMode フィールドで通知」、:781-787 MUST 群 — 特に :786「Host MUST NOT switch the View to
>   a display mode that does not appear in its appCapabilities.availableDisplayModes」、
>   :787「Host MUST return the resulting mode(変えなかった場合も)in the response」)、
>   :1036-1056(`ui/request-display-mode` のワイヤ形式: request `params.mode`、
>   success response `result.mode` = 実際に設定されたモード)、
>   :1204-1212(`ui/notifications/size-changed`)
> - ext-apps 型定義: ~/ghq/github.com/modelcontextprotocol/ext-apps/src/spec.types.ts
>   :39(McpUiDisplayMode)、:357/:362(McpUiHostContext.availableDisplayModes / containerDimensions —
>   height|maxHeight × width|maxWidth の組)、:547(McpUiAppCapabilities.availableDisplayModes)、
>   :739-751(McpUiRequestDisplayModeRequest / Result)、:842-843(REQUEST_DISPLAY_MODE_METHOD =
>   "ui/request-display-mode")。node_modules 側
>   (~/ghq/github.com/gigun-dev/caldav/node_modules/@modelcontextprotocol/ext-apps/dist/src/spec.types.d.ts
>   :27,154,236-248,413,596-611)でも同一契約を確認済み — caldav が実際に積んでいる SDK と spec 本体が
>   一致している(バージョン齟齬なし)。
> - ext-apps App SDK(カード側の口): ~/ghq/github.com/modelcontextprotocol/ext-apps/src/app.ts
>   :739(`getHostContext()` — initialize result の hostContext を保持 :1978)、
>   :451(host-context-changed 受信で `_hostContext` に **merge** — ホストの部分更新パッチが効く)、
>   :1788-1800(`app.requestDisplayMode(params)` — "ui/request-display-mode" request を送る実装)、
>   :1775-1783(公式例: getHostContext().availableDisplayModes を確認してから requestDisplayMode)
> - caldav カード実体: ~/ghq/github.com/gigun-dev/caldav/src/presentation/mcp/ui/
>   todos-entry.ts:172(#quick-add-fab 参照)、:177(#header-done 参照)、:2781(`new App({...})` —
>   autoResize 既定 ON)、:2800(app.connect)。**hostContext / getHostContext / requestDisplayMode /
>   host-context-changed への言及ゼロ(grep で確認)= カード側は containerDimensions を読んでいない**。
>   todos-app.ts:1151(`<header class="bar">`)、:1173(#header-done — hidden、編集モードで出現)、
>   :1203(#quick-add-fab — :680,:1185-1198 の通り v2.2 item4 で position:fixed を撤廃し
>   **通常フロー右寄せ**)。sticky/fixed の測位は現在ゼロ。
> - 本アプリ: Sources/Services/AppsBridge/AppsBridgeSession.swift:53-54,74,132-145,253-279,298-306、
>   Sources/Features/Chat/InlineCardView.swift:79,97-105,107-133,269、
>   Sources/Kernel/AppsProtocol/UIMessages.swift:33-81,108、
>   Sources/Kernel/AppsProtocol/IncomingViewMessage.swift:11-31

## 0. 問題と全体像

インラインカードは現在「内部スクロール無効 + size-changed の max-content 高さに `.frame(height:)`
追従(上限 4000pt の安全網のみ)」。todos 9件で全行は見えるが、カードが画面高を超えると
**カード上端の『完了』(編集確定)と下端の『+』(追加)が同時に見えず、チャット全体を
スクロールし直さないと確定操作に到達できない**。かといって高さキャップ + 内部スクロールは
「チャットスクロール × カード内スクロールの二重化」としてユーザーが既に却下済み(InlineCardView.swift:73-79
のコメントに経緯)。

**結論: これは SEP-1865 がプロトコルレベルで解を用意している問題**であり、独自のハックではなく
spec の標準語彙 3 点セットに乗る:

1. **ホストが inline の空間制約を宣言する** — `HostContext.containerDimensions.maxHeight`
   (apps.mdx:671-733。「ホストが上限を宣言し、View がその中で自分をレイアウトする」が spec の想定)。
2. **カードが大きい UI をモード昇格で要求する** — `ui/request-display-mode`(apps.mdx:1036-1056)。
3. **ホストがモード変化を通知する** — `ui/notifications/host-context-changed` の `displayMode`
   フィールド + 新しい containerDimensions(apps.mdx:776)。

層はこう切る(01〜03 と同じレイヤー図):

```
Sources/
├── Kernel/          # AppsProtocol — RequestDisplayModeParams/Result の Codable 型を追加
│                    # (UIDisplayMode / ContainerDimensions / HostContext は既存 :33-81)、
│                    # TypedViewMessage に .requestDisplayMode ケース追加(classify の typed レーン)
├── Services/
│   └── AppsBridge/  # AppsBridgeSession — ネゴシエーションの担保点:
│                    #   availableDisplayModes: [inline, fullscreen] の広告、
│                    #   ui/request-display-mode の受理 → Features へ委譲 → result.mode 応答、
│                    #   モード遷移時の host-context-changed(displayMode + containerDimensions)送出
├── Features/        # InlineCardView / 新 FullscreenCardPresenter — 実 maxHeight の算出
│                    # (可視高 × 係数)、.sheet / fullScreenCover への同一 WKWebView の reparent
└── (caldav 側)     # todos-app.ts / todos-entry.ts — 制約内レイアウト戦略:
                     #   sticky ヘッダ・N 件 + 「すべて表示」・requestDisplayMode 発火・
                     #   fullscreen 時のみ内部スクロール解禁
```

## 1. 現状の実装(読んで確認した事実)と変更後の差分

### 現状

- **containerDimensions は既に initialize 応答で送っている(未実装ではない)**。
  AppsBridgeSession.swift:253-279 `handleInitialize` が
  `HostContext(theme: .light, locale: "ja-JP", displayMode: .inline, availableDisplayModes: [.inline],
  containerDimensions: ContainerDimensions(width: containerWidth, maxHeight: maxHeight))` を返す。
  幅変化は :132-145 `setContainerWidth` が host-context-changed の部分パッチ
  (containerDimensions のみ)で送る。Kernel 型(UIMessages.swift:33-81)も
  UIDisplayMode / ContainerDimensions / HostContext まで揃っている。
- **ただし maxHeight が「安全網 4000」であり空間制約として機能していない**。
  InlineCardView.swift:79 `inlineCardMaxHeight = 4000` → :114 で session の maxHeight に渡り、
  :123-124 の onSizeChanged クランプ `min(height, 4000)` → :269 `.frame(height:)` 追従。
  カードから見ると「maxHeight: 4000 の flexible container」= 実質無制限。
- **availableDisplayModes は [.inline] 固定**(AppsBridgeSession.swift:256 コメント
  「fullscreen/pip はスパイク外」)。
- **`ui/request-display-mode` は未処理**。TypedViewMessage(IncomingViewMessage.swift:11)は
  initialize / initialized / sizeChanged / openLink の 4 種のみで、未知 request は
  AppsBridgeSession.swift:298-306 で **-32601 Method not found** になる。もしカードが今
  requestDisplayMode を投げたらエラーが返る(spec 上は View が :782 の MUST を守れば
  そもそも投げてこない — ホストが [inline] しか広告していないため)。
- **caldav カードは hostContext を一切読んでいない**(出典行の grep 結果)。autoResize 既定 ON の
  ResizeObserver で max-content 高さを size-changed 送信するだけ。ヘッダは通常フロー
  (todos-app.ts:1151)、FAB も通常フロー右寄せ(:1203、v2.2 item4 で fixed 撤廃)、
  #header-done は編集モードでのみ出現する hidden ボタン(:1173)。

### 変更後(差分の要点)

| 項目 | 現状 | 変更後 |
|---|---|---|
| inline maxHeight | 4000(安全網・実質無制限) | 可視高ベースの実制約(例: `floor(可視高 × 0.65)`。係数は実機で調整) |
| availableDisplayModes | `[inline]` | `[inline, fullscreen]`(pip は当面出さない) |
| ui/request-display-mode | -32601 | typed レーンで受理 → Features へ委譲 → `result.mode` 応答(apps.mdx:787 の MUST) |
| モード遷移通知 | なし | host-context-changed に `displayMode` + 新 containerDimensions(apps.mdx:776) |
| fullscreen の器 | なし | SwiftUI `.sheet`(large detent)or `fullScreenCover` に同一 WKWebView を reparent |
| caldav カード | hostContext 不読 | maxHeight を読み sticky ヘッダ + N 件畳み + 「すべて表示」→ requestDisplayMode |

## 2. 決定

### 決定 1: inline の containerDimensions.maxHeight を「実制約」にする(4000 安全網の廃止)

- Features(InlineCardView 側)が可視高から実 maxHeight を算出して session へ渡す。初期値は
  **可視高の 65%**(spec の例 :616 も maxHeight:600 と「画面より小さい inline」を例示している)。
  係数はモック/実機で合意後に確定する — この値の変更は 1 定数で、完全に可逆。
- size-changed のクランプ(InlineCardView.swift:123-124)はこの実 maxHeight に対して行う。
  **二重スクロールは発生しない**: maxHeight 内に収まる(少数件)ならカードは従来通り
  内容ぴったりで全部見え、超える場合はカード側が「畳み」で maxHeight 内に自己整形する(§3)。
  ホストは相変わらず scrollEnabled=false のまま(inline では)。
- spec 整合: containerDimensions は「View が占める実空間をホストが制御する」ためのフィールド
  (apps.mdx:673)であり、View は「containerDimensions を確認して適切な CSS を当てるべき」
  (:687-711、`maxHeight` なら `document.documentElement.style.maxHeight` を当てる公式例)。
  つまり「max-content に無限追従」は spec の flexible 運用の**片側だけ**を実装した状態だった。
  4000 という番兵値は「maxHeight を実装していないことの代替」であり、本決定で廃止する。

### 決定 2: fullscreen をホストの displayMode として実装し、昇格はカード発の `ui/request-display-mode` に限る

- ホストは `availableDisplayModes: [.inline, .fullscreen]` を initialize の hostContext で広告
  (apps.mdx:768)。**ホスト側から勝手に fullscreen に切り替えることはしない** — :786 の
  「View の appCapabilities.availableDisplayModes に無いモードへ MUST NOT switch」があり、
  現行 caldav カードは appCapabilities を宣言していないため、昇格の起点は常にカード側の
  requestDisplayMode(:772)。ホストは受理して sheet を出し、`result.mode` で実際のモードを返し
  (:787 MUST — ユーザーが即閉じた等で昇格しなかった場合は "inline" を返してよい)、遷移確定後に
  host-context-changed で `displayMode: "fullscreen"` + sheet 実寸の containerDimensions を通知(:776)。
- **fullscreen の器は `.sheet` + `.presentationDetents([.large])`**(fullScreenCover ではなく)。
  チャット文脈への「戻り」がスワイプで自然に効き、モーダル脱出の学習コストがゼロ。
  claude.ai の inline apps も「上限付き inline + 展開でフル表示」の文法で動いており、
  ユーザーのメンタルモデルと一致する。sheet 却下時(スワイプで閉じる)は inline へ戻し、
  host-context-changed で `displayMode: "inline"` + inline の containerDimensions を再通知する。
- **同一 WKWebView を reparent する**(新規ロード禁止)。カードの状態(編集途中・楽観適用中の
  トグル)は WKWebView 内の JS 状態なので、作り直すと飛ぶ。InlineCardHost が webView を
  強保持する既存設計(InlineCardView.swift:39-70)はそのまま使え、sheet は「host.webView を
  別の場所に載せるだけ」。spec はホスト内部の実装(iframe/WebView の移設)には関知しない —
  spec 上の表現はあくまで host-context-changed による dimensions/displayMode の再通知である。
  > **2026-07-16 更新(reparent スパイクで JS 状態保持を実証・§6-1):** 同一 webView の載せ替えで
  > JS 状態は完全保持される(逃げ道の別 UIWindow/overlay は不要=削除)。**ただし reparent は
  > AppCardView の「container 再アダプト方式」で実装する**: makeUIView は空の container UIView を
  > 返し、updateUIView が「host.webView が自分の container に載っていなければ addSubview + 制約張り直し」
  > をする(冪等)。これは inline-only 経路にも全面適用する — LazyVStack のスクロール往復(View
  > 破棄→再生成)に対してもむしろ堅牢になる良性の波及で、Representable は inline/sheet 共通の 1 種で済む。
  > **【最重要・奪い合いガード】再アダプトは displayMode ガード付きにする**: inline 側 container は
  > `host.displayMode == .inline` のときだけ adopt、sheet 側は `.fullscreen` のときだけ adopt する。
  > これが無いと「sheet 表示中にチャットがスクロールして inline 行が再生成された瞬間、inline が
  > sheet から webView を奪う」バグを踏む(スパイクの単純往復では露見しなかったシナリオ・§6)。
  > displayMode を InlineCardHost の @Observable な単一の真実にすれば(§3 責務表)、View は
  > 「host.displayMode が自分のモードなら adopt」という純関数的振る舞いになり、このガードが自然に書ける。
  > dismiss 時の順序は **rehome(inline container へ)→ scrollEnabled=false → host-context-changed
  > (displayMode:inline + inline の containerDimensions)** に固定する(寸法通知が reparent より先だと
  > カードが旧寸法でレイアウトする)。
- fullscreen 中は **カード側が内部スクロールを持つ**(§3)。コンテナが sheet 1 枚しかないので
  二重スクロール問題は構造的に消滅する。ホスト側も fullscreen 中は
  `webView.scrollView.isScrollEnabled = true` に切り替える(inline へ戻すとき false へ)。
  ※現在 scrollEnabled は AppCardWebViewFactory.make の生成時引数(InlineCardView.swift:104-105)
  なので、動的切替の口を足す(要検証 — §6)。
- **fullscreen 中は size-changed による `.frame` 追従を停止する**。sheet 中はカードが
  `overflow-y:auto` で自己スクロールし寸法は sheet 固定なので、onSizeChanged の高さ反映は無視し、
  inline 復帰時に最後の値だけ反映する。

### 決定 2b: fullscreen は常に高々 1 カード(2026-07-16 追加)

sheet は同時に 1 枚しか出せない。既に 1 カードが fullscreen 昇格中に別カードが
`ui/request-display-mode` を投げたら、ホストは昇格させず `result.mode: "inline"` を返す
(apps.mdx:787「モードを変えなかった場合も結果のモードを返す」に適合)。この調停(「今どのカードが
fullscreen か」の単一状態)はカード横断の判断なので単一の InlineCardHost には置けず、
**ChatBodyView 層(InlineCardRegistry の隣)**に置く。スパイクの単純往復では露見しなかった
本番シナリオ(§6 の追加検証項目)。

### 決定 3: 制約内のレイアウト戦略は全てカード(caldav)の責務

caldav 側(todos-app.ts / todos-entry.ts)の変更。実在の DOM に即して:

1. **`getHostContext().containerDimensions` を読む口を作る**(app.ts:739。現状ゼロ)。
   `maxHeight` があれば CSS 変数(例: `--host-max-height`)に落とす。host-context-changed は
   SDK が _hostContext に merge する(app.ts:451)ので、変化の購読も SDK 経由で足す。
2. **`<header class="bar">`(todos-app.ts:1151)を `position: sticky; top: 0` にする**。
   #header-done(:1173)はヘッダ内なので自動で常時可視になる。inline で maxHeight に収まって
   いる間は sticky は無効果(スクロールが無い)、fullscreen の内部スクロール時に効く。
3. **inline(displayMode === "inline")で内容が maxHeight を超える場合、行リストを先頭 N 件に
   畳み、末尾に「すべて表示 (全n件)」ボタンを出す**。タップで
   `app.requestDisplayMode({ mode: "fullscreen" })`(app.ts:1788)。要求前に
   `getHostContext().availableDisplayModes` に "fullscreen" が含まれるか確認する(apps.mdx:782 MUST
   — 含まれないホスト(claude.ai 等で inline のみの場合)では畳んだまま。ボタンは出さないか、
   セクション単位の開閉に落とす)。
4. **`new App({...})`(todos-entry.ts:2781)に `appCapabilities.availableDisplayModes:
   ["inline", "fullscreen"]` を宣言**(apps.mdx:781 MUST)。これが無いとホストは :786 により
   fullscreen へ切り替えられない — **caldav 側のこの宣言が昇格フロー全体の前提**(順序制約 §5)。
5. **fullscreen 時のみ `overflow-y: auto` を root に当て、全件表示**。FAB(:1203、通常フロー
   右寄せ)は全件リストの末尾に出る — fullscreen では sticky ヘッダの『完了』と併せて
   「上端の確定・下端の追加」が 1 画面のスクロール内で完結する。

このカードのコメント規律(v2→v3 の経緯コメント文化)に合わせ、写経する契約には
apps.mdx / spec.types.ts の出典行をコメントで残す。

## 3. 責務の切り分け(原則)

| 責務 | 置き場 | 根拠 |
|---|---|---|
| inline の空間上限(何 pt まで) | ホスト(Features が算出 → Session が宣言) | containerDimensions はホストの宣言(apps.mdx:673)。どのサーバーのカードにも一律 |
| モード遷移の可否・器(sheet) | ホスト(Session 受理 → Features 表示) | :787 の応答 MUST・:776 の通知 MUST はホスト側規範 |
| 制約内で何をどう見せるか(sticky・畳み・N 件) | カード(caldav HTML) | :687-711「View は containerDimensions を確認して CSS を当てる」。ヘッダ/FAB の位置はカードの裁量 |
| いつ fullscreen を要求するか | カード | :772 要求は View 発。:782 の事前確認もカードの MUST |
| **displayMode の真実(single source of truth)** | **InlineCardHost に @Observable で新設** | View(inline/sheet)は「host.displayMode が自分のモードなら adopt」の純関数的振る舞いになり、奪い合いガード(決定2)が自然に書ける。Session はワイヤ表現(host-context-changed 送出)のみで**状態を持たない** |
| 再アダプト(UIKit 階層操作) | AppCardView(updateUIView) | 階層操作は Representable の責務。判断(どちらが載せるか)は host.displayMode を読むだけ |
| 同時 fullscreen の調停(高々 1 枚) | ChatBodyView(registry の隣) | カード横断の判断は単一 host に置けない(決定2b) |

**判定基準: 「他の任意の MCP App にもそのまま当てはまるか?」YES ならホスト、NO ならカード。**
「完了ボタンが上端にある」「todos は N 件で畳むのが自然」は caldav の事情なので、ホストに
1 バイトも漏らさない(ビジョン2: AppsBridgeSession は caldav 非依存 — 同ファイル :25 の既存宣言を維持)。
ホストが足すのは spec の標準語彙(maxHeight / displayMode / request-display-mode)だけであり、
これは中立性を損なうどころか **spec 準拠度を上げる**(= 「Swift で MCP Apps ホストを実装した」という
コア価値の主張が強くなる)。

## 4. ボツ案(財産として残す)

- **現状維持(max-content 無限追従)**: 到達性問題そのもの。9 件で既に破綻が見えており、
  件数に上限が無い以上、悪化は必然。却下。
- **高さキャップ + 内部スクロール復活(sticky ヘッダ等で緩和)**: 二重スクロールとして
  ユーザーが既に却下済み(InlineCardView.swift:73-79 の経緯コメント)。iOS の UIScrollView
  入れ子はジェスチャ競合(どちらが掴むか)の不確定性が本質で、「緩和」では消えない。却下。
- **軽量プレビュー + タップで sheet 展開(ホスト独自のプレビュー契約)**: 「プレビューとは何か」を
  カードごとに定義する独自契約が必要になり、spec 外の語彙が増える。本決定はこの案の
  spec 準拠版 — 「プレビュー = inline maxHeight 内のカード自己整形」「展開 = request-display-mode」
  と読み替えれば同じ UX を標準語彙だけで実現できる。独自契約としては却下。
- **『完了』ボタンをホスト側チャット行(カード外)に昇格**: ホストが「このカードには確定操作が
  ある・その意味は何か」という caldav の DOM/意味論を知る必要があり、中立性(ビジョン2)違反。
  カードが増えるたびにホスト改修が要る不可逆コミット。却下。
- **インラインは表示専用・操作は全画面のみ**: 「チャットの流れの中でチェックを打つ」という
  inline カードの主価値(todos-entry.ts 冒頭 :83-88 のカード自身の設計宣言とも一致)を捨てる。
  却下。
- **pip も同時に実装**: 現時点でカード側にユースケースが無く、器(フローティングオーバーレイ)の
  実装コストだけ先払いになる。availableDisplayModes への追加は後からでも 1 要素で、完全に可逆。
  今回は見送り(却下ではなく遅延)。

**可逆性の総括**: 本決定は全て spec の標準語彙の実装であり、maxHeight 係数・detent・畳み件数 N は
いずれも 1 定数の調整で可逆。唯一準・不可逆なのは「独自契約を作らない」という不作為の選択で、
それが本決定の核心(独自契約は一度カードが依存すると剥がすのが重い)。

## 5. 実装ステップ(P4 として)

順序制約: **caldav 側 4(appCapabilities 宣言)とホスト側 H2〜H3 が揃って初めて昇格フローが通る**。
ただし H1(maxHeight 実制約化)と C1〜C3(sticky・畳み)は独立に先行でき、それだけでも
「収まらないカードが暴れる」問題は解消する(畳んだ状態で完結)。

> **2026-07-16 更新(H2+H3 完了後の推奨実装順を確定 — fable):**
> `[H4 モック合意ゲートを即時並行で発火]` → **① C1+C2**(caldav・統合)→ **② H1**(ホスト)→
> **③ H4**(モック合意後)→ **④ C3**(caldav・full ループ完成)。
> 根拠: H1 を先にやると C2 の受け皿が無く 65% でクリップして悪化するので、カード側の畳み(C1+C2)が先。
> C1 は「読むだけ」で単独観測不能なので C2 と同一ブロックに統合。各ステップは独立コミット可能で
> どこで止まっても退行ゼロ。中間観測: ①claude.ai で sticky/畳みが見える・本アプリ(maxHeight=4000)は
> 無風、②本アプリで 9 件 todos が可視高 65% に畳まれ sticky で「完了」常時可視、③reparent 器単体で動く、
> ④full ループ(「すべて表示」→ 最大化 → 操作 → dismiss で状態保持)。
> **「すべて表示」ボタンは C2 → C3 へ移動**(C2 は受動的「残り n 件」表示まで。requestDisplayMode 発火と
> 不可分なので、押しても何も起きないボタンを中間状態に作らない)。
> **H3 追補**: availableDisplayModes の **fullscreen 広告は onDisplayModeRequested ハンドラ注入時のみ**に
> する(既定拒否のまま fullscreen を広告する中間状態=「押すと必ず拒否される死にボタン」を構造的に排除)。
> H4 実装時に AppsBridgeSession の広告ロジックを「ハンドラ有無で分岐」に 1 行追補する。

### ホスト側(swift-mcp-app)

- **H1: inline maxHeight の実制約化**
  - InlineCardView: `inlineCardMaxHeight = 4000` を廃止し、可視高 × 0.65(GeometryReader or
    UIScreen 由来。算出はFeatures)を InlineCardHost.buildIfNeeded 経由で session に渡す。
    onSizeChanged クランプも同値に。
  - swift-testing: なし(Features のみ)。実機で「9 件 todos が maxHeight で止まり、カードが
    畳み UI(C2 後)を出す」ことを確認。
- **H2: Kernel 型 + typed レーン**(swift-testing 単体で回る)
  - Kernel/AppsProtocol/UIMessages.swift に `RequestDisplayModeParams { mode: UIDisplayMode }` /
    `RequestDisplayModeResult { mode: UIDisplayMode }` を追加(出典: apps.mdx:1036-1056、
    spec.types.ts:739-751)。HostContext に displayMode 入り部分パッチが既に表現可能なことを確認済み
    (UIMessages.swift:66-81 — 全フィールド optional)。
  - IncomingViewMessage.TypedViewMessage に `.requestDisplayMode(id:params:)` を追加、
    classify のテスト(round-trip + malformed)を追加。
- **H3: Session のネゴシエーション**
  - handleInitialize の availableDisplayModes を `[.inline, .fullscreen]` へ。
  - `.requestDisplayMode` ハンドラ: 注入コールバック
    `onDisplayModeRequested: (UIDisplayMode) async -> UIDisplayMode`(Features が実モードを返す)を
    呼び、返ったモードで `result.mode` を応答(apps.mdx:787)。続けて host-context-changed で
    `displayMode` + 新 containerDimensions を送出(:776)。onSizeChanged と同じ注入点パターン
    (AppsBridgeSession.swift:58)。
  - swift-testing: 「request → result.mode 応答 → host-context-changed 送出」の順序をモック
    transport で検証。inline しか返さないコールバックのケース(昇格拒否)も。
  > **2026-07-16 更新(H2+H3 実装完了・make check green):** 実装は上記どおり。加えて **`AppsBridgeTransport`
  > プロトコルを新設**した(Sources/Services/AppsBridge/WebViewTransport.swift)。理由: Session は具象
  > `WebViewTransport`(WKWebView 必須)に直接依存しており単体テストで送信内容を観測できなかったため、
  > Session が使う面(incoming / deliver(rawJSON:) / deliver(response:) / finish())だけをプロトコルに
  > 切り出し、テストは軽量な MockTransport を注入。`WebViewTransport` は extension で自動適合し**本番配線は
  > 無変更**。可逆・影響最小の seam。DisplayModeResolution(mode + containerDimensions?)は指示どおり
  > Services 内 struct(Kernel の wire 型と分離)。テスト: 昇格受理(応答→通知の順)・既定拒否(通知なし)・
  > notifyDisplayModeChanged の3本 + Kernel classify/Codable 4本。
- **H4: Features の fullscreen 器**(**モック/プレビューでユーザー合意してから実装** —
  「UI はモックで合意してから実装」の規律)
  > **2026-07-16 モック合意済み:** 器は「**カードが sheet 全面・ホストはグラバー(チキ)のみ・
  > カード自前の sticky ヘッダ(tasks/完了)がそのまま上端に出る・内部スクロール・下スワイプ or
  > 『完了』で inline に戻る**」。ホストのナビバー(タイトル+閉じるボタン)は重ねない案は却下
  > (カードの『完了』と二重になる)。= ホスト/カードの役割が重ならず中立(ビジョン2)。
  - **InlineCardHost に `displayMode`(@Observable)を新設** = 単一の真実(§3 責務表)。Session は状態を持たない。
  - **AppCardView を container 再アダプト方式へ全面変更**(inline-only 経路含む):makeUIView は空の
    container UIView を返し、updateUIView が **displayMode ガード付きで** adopt する(inline 側 container は
    `host.displayMode == .inline` のときだけ・sheet 側は `.fullscreen` のときだけ host.webView を addSubview +
    制約張り直し。冪等)。これで sheet 表示中の LazyVStack 行再生成による奪い合い(§6-新)を構造的に防ぐ。
  - sheet(large detent)に host.webView を reparent、`scrollView.isScrollEnabled` を true へ切替、
    sheet 実寸を session へ渡す(host-context-changed の材料)。**dismiss の順序は rehome → scrollEnabled=false →
    host-context-changed(inline)で固定**。fullscreen 中は onSizeChanged の `.frame` 追従を停止。
  - **受理時(onDisplayModeRequested)が返す resolution 寸法は画面 bounds からの推定値**(large detent ≒
    可視高 − トップインセット)にする。sheet の実寸は提示アニメーション完了まで確定しないため、提示完了後に
    実寸が有意にズレたら setContainerWidth と同型の追加 host-context-changed で補正する(fullscreen は
    カード内部スクロールなので高さ誤差の実害は小さく、幅が合っていれば足りる・2026-07-16 fable 指摘)。
  - **availableDisplayModes の fullscreen 広告はこのハンドラを注入したときだけ**にする(H3 の広告ロジックを
    「onDisplayModeRequested 注入の有無で分岐」に 1 行追補)。既定拒否のまま広告する死にボタン中間状態を排除。
  - **rehomeToken は displayMode 観測での再評価が効かない場合の保険**として持つ(スパイクでは View 側
    @State の rehomeToken bump で inline 復帰を確認済み。displayMode を @Observable にすれば bump 不要に
    なる可能性が高い — §6 の検証項目で確定する)。
  - **決定2b の調停**(高々 1 fullscreen)は ChatBodyView に置く: 昇格中に別カードが要求したら
    onDisplayModeRequested が inline を返し、Session が `result.mode:"inline"` を応答する。
- 判断ゲート:
  - [ ] H1+C2 後、実機で todos 9 件が inline maxHeight 内に畳まれて表示される
  - [ ] H3+H4+C3 後、「すべて表示」→ sheet 全件 → 完了/追加操作 → dismiss → inline に状態が残る

### caldav 側

- **C1+C2(統合ブロック・最初に着手): hostContext 読み口 + sticky/畳み**
  - C1: todos-entry.ts に `app.getHostContext()`(app.ts:739)から containerDimensions.maxHeight /
    displayMode / availableDisplayModes を読み `--host-max-height` CSS 変数に反映するユーティリティ +
    host-context-changed の購読(SDK フックの有無は app.d.ts で確認・§6)。出典コメント(apps.mdx:687-711)。
  - C2: todos-app.ts の `.bar`(:1151)に `position:sticky;top:0`、行リストの N 件畳み(初期 6)と
    **受動的な「残り n 件」表示**(ボタンではない)。maxHeight が有限 **かつ displayMode==="inline"** の
    ときだけ発火 — maxHeight 情報が無いホスト(現本アプリ=4000・未送信)では全件のまま**不活性が既定**。
    畳みは renderAll 最終段の「表示切り」だけで行い、vm/セクショニング/楽観適用(todos-entry.ts:404-425)を汚さない。
  - **「すべて表示」ボタンは C2 には置かない**(C3 へ移動 — requestDisplayMode 発火と不可分)。
- **C3: 昇格(full ループの最後)**: `appCapabilities.availableDisplayModes: ["inline","fullscreen"]` 宣言
  (todos-entry.ts:2781 の `new App`)+ C2 の「残り n 件」表示を **「すべて表示 (全n件)」ボタンに置換** →
  `app.requestDisplayMode({mode:"fullscreen"})`(fullscreen が広告されているホストのみ・無ければ受動表示のまま)
  + fullscreen 時 `overflow-y:auto`。
- caldav 側の検証は既存の実機 + D1 生 ICS 裏取りの流儀に従う。claude.ai(fullscreen 対応ホスト)でも
  退行しないこと(availableDisplayModes 分岐が正しく効くこと)を確認。

## 6. 未確認・要検証(推測で断定しない)

1. ~~**WKWebView の reparent で JS 状態・プロセスが保たれるか** — SwiftUI 階層間の移設は P2 スパイクで
   未検証。UIViewRepresentable の再マウントで WKWebView が再ロードされないことを実機で確認する
   (だめなら sheet を「同じ webView を持つ別 UIWindow / overlay」に変える逃げ道あり)。~~ ✅ **検証済み**
   > **2026-07-16 更新(reparent スパイクで実測・Sources/Features/Spike/ReparentSpikeView.swift、
   > MCPHOST_SPIKE=reparent [+ MCPHOST_SPIKE_AUTO=1] で再現可):**
   > 単一 WKWebView に「100ms 毎に +1 する tick(リロードで 0 に戻る)+ 手動カウンタ + 入力欄」を仕込み、
   > inline → sheet → dismiss の各段で JS 状態と superview を os_log(category=reparent-spike)に吐いて測定。
   > 結論2点:
   > - **(a) JS 状態は reparent を跨いで完全保持される。** tick は 11→15→29→44→53 と単調増加(リセット無し)、
   >   手動カウンタ=5・入力欄="hello" も全段で維持。**Web プロセスは載せ替えで再ロードされない**
   >   (= 逃げ道の別 UIWindow/overlay は不要。同一 webView を `.sheet` に載せてよい)。決定2の核心的前提が成立。
   > - **(b) ただし素朴実装は dismiss 後に webView が orphan(superview=nil)になり inline が空白化する。**
   >   inline と sheet の2つの UIViewRepresentable が同じ webView を直接 return すると、sheet 提示で
   >   webView が sheet 側へ移り、SwiftUI は dismiss 時に inline 側 makeUIView/updateUIView を
   >   **再評価しない**ため webView がどこにも載らない(第1回スパイクで実測・スクショで inline 空白確認)。
   >   **対処(検証で有効確認):** ①各所は webView を直接返さず「空の container UIView」を返し、
   >   updateUIView で「自分の container に載っていなければ載せ直す(再アダプト)」。
   >   ②dismiss を機に inline を再レンダーさせる(inline 側 Representable に `rehomeToken: Int` を渡し、
   >   `.sheet` の onDismiss で bump)。この2点で dismiss 後 superview=UIView に戻り、tick=79 で継続・
   >   手動カウンタ=5 保持のまま inline にカードが復帰した(第3回スパイク・スクショ確認)。
   >   → **本番 InlineCardHost/AppCardView も「container 再アダプト + dismiss での rehome トークン」方式で実装する。**
   > 残る細目: (b) の rehome を InlineCardRegistry の webView 保持設計にどう馴染ませるか(host は既に
   > webView を強保持しているので、View 側の再アダプトだけで足りるはず)は H4 実装時に詰める。
2. **scrollEnabled の動的切替** — 現在は AppCardWebViewFactory.make の生成時引数。
   `webView.scrollView.isScrollEnabled` の実行時切替で足りるはずだが未検証。
   > 2026-07-16: reparent スパイクで sheet の onAppear/onDisappear から `isScrollEnabled` を
   > true/false 切替してクラッシュ無く動作したが、実カードでの内部スクロール挙動そのものは未確認。
6. **【新】sheet 表示中に LazyVStack がスクロールして inline 行が再生成されても、inline 側が
   sheet から webView を奪わないこと** — 決定2の displayMode ガードの実機確認。スパイクの単純
   往復では露見しなかった本番シナリオ(fable 指摘)。
7. **【新】displayMode(@Observable)の変化観測だけで inline 側 updateUIView が再評価されるか** —
   されれば rehomeToken は不要(保険として削除可)。されなければ rehomeToken bump を正式採用。
8. ~~**【新】ext-apps App SDK に host-context-changed の購読フックが公開されているか**~~ ✅ **確認済み**
   > 2026-07-16(C1 実装時): `app.addEventListener("hostcontextchanged", handler)` が公開されている
   > (app.d.ts:178,219,239,567-582,715-745。非推奨版 `onhostcontextchanged` も同義)。SDK は受信時に
   > 内部 `_hostContext` へ merge した後ハンドラを呼ぶ(app.d.ts:723-727)ので、ハンドラ内で
   > `getHostContext()` を読み直すだけで追従できる。polling ワークアラウンド不要。caldav-feedback.md への
   > 起票も不要(フックが「在る」ことが判明したため)。
3. **sheet detent と containerDimensions 再通知のタイミング** — sheet 提示アニメーション中に
   size を送ると中間値を掴む可能性。提示完了(onAppear + レイアウト確定)後に送る。要実機。
4. **claude.ai が todos カードに実際どの availableDisplayModes を広告しているか** — C2 の
   フォールバック分岐の実地確認(claude.ai 上で getHostContext をログる)。
5. **maxHeight 係数 0.65 の妥当性** — キーボード表示時・Dynamic Type 大での可視高変動を含め
   実機で調整。設計上は 1 定数なのでいつでも変えられる。

## 7. 決定サマリ

1. **inline は containerDimensions.maxHeight(可視高 × 0.65)の実制約にする** — 4000 番兵は
   「spec の maxHeight 未実装の代替」だったので廃止。二重スクロールは発生しない(超過分は
   カードが畳む)。
2. **fullscreen displayMode を実装し、昇格はカード発 `ui/request-display-mode` のみ** —
   ホストは availableDisplayModes 広告・result.mode 応答・host-context-changed 通知という
   spec の MUST 群を実装するだけで、caldav 固有知識ゼロ。器は sheet(large detent)+
   同一 WKWebView reparent。**reparent は実測で JS 状態保持を確認済み(§6-1)** — 実装は
   AppCardView の container 再アダプト + displayMode ガード方式(inline 側は .inline のとき・
   sheet 側は .fullscreen のときだけ adopt し、スクロール時の奪い合いを防ぐ)。**fullscreen は
   常に高々 1 カード**(決定2b・調停は ChatBodyView)。
3. **sticky ヘッダ・N 件畳み・「すべて表示」・fullscreen 時の内部スクロールは全て caldav 側** —
   判定基準「他の任意の MCP App にも当てはまるか」で切る。caldav は appCapabilities の
   availableDisplayModes 宣言(spec MUST)が昇格フローの前提。
4. 独自契約(プレビュー定義・確定ボタンのホスト昇格)は作らない — それが本決定で唯一の
   準・不可逆な選択であり、核心。

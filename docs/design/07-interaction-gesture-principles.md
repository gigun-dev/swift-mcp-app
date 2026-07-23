# 07. ジェスチャ・指追従の設計原則(2026-07-23)

> 位置づけ: drawer・カード・fullscreen などの「指追従 UI」を実装・修正するときの設計の正。
> 編集時の要約ルールは `.claude/rules/interaction.md`(このドキュメントの運用ダイジェスト)。

## 経緯(Why このドキュメントが要るか)

境界追従のカクつきは一度きりの不具合ではなく、実装のたびに形を変えて再発してきた:

- drawer のゆっくりドラッグで境界が跳ねる(2026-07-23 修正)。根因は
  `SidebarGesturePolicy.liveTranslation` が**累積** translation の縦横比較を**毎フレーム**
  行っていたこと。ゆっくりした指では横と縦の累積が拮抗し、判定が毎フレーム反転して
  出力が「実値 ↔ 0」を往復した。フリックは横成分が圧倒的なので露見しない —
  「速い操作では正常・遅い操作でカクつく」はこのクラスの不具合の典型シグネチャ。
- 同型の判定(帯除外・commit 閾値)が gesture ごとに増えるたび、毎フレーム再判定の
  誘惑が再生産される構造だった。
- 軸ロック修正(81ace79)後も drawer のゆっくりドラッグで境界の残振動が残った(2026-07-23・第2根因)。
  録画のフレーム解析で、境界が「進む→約2フレーム遅れ位置へ戻る」を交互に繰り返す2系列交互振動を確認。
  根因は座標空間のフィードバックループ: DragGesture を `.offset(x:)` で動くビュー自身に付け、既定の
  `.local` 空間で translation を測っていた。offset 適用 → 名前付き/ローカル空間が右へ動く → 次フレームの
  translation が縮む → offset が戻る、が毎フレーム繰り返される。振幅≒速度×遅延なので速いフリックでは
  知覚されず、ゆっくりドラッグでだけ露見する(軸ロックと同じ「速い操作では正常」シグネチャ)。
  修正は translation・startLocation を offset の外側の不動 named 空間で測ること(P5)。

## 原則

### P1. 判定は one-shot、追従は連続

ジェスチャに対する**分類**(横か縦か・許可帯か拒否帯か・tap か drag か)と、
**追従**(指の移動を offset へ写す)を分ける。

- 分類はジェスチャ開始時に一度だけ決めて `@State` に固定し、onEnded で破棄する。
  UIScrollView の direction lock、UIGestureRecognizer の began/failed と同じモデル。
- 追従は分類が確定した後の純粋な写像にする。写像の中に分類をやり直す分岐を置かない。

### P2. 追従出力は入力に対して連続

onChanged が state へ書く値は、指の入力列が連続なら出力列も連続でなければならない。

- clamp(`min/max`)は連続なので可。
- 「条件を満たさないので 0」のようなリセット分岐は不連続なので、ライブ追従経路には置かない。
  リセットしてよいのは onEnded の確定遷移だけ。

### P3. 判定は Kernel 純関数 + 連続性テスト

- 分類・閾値・写像は `Sources/Kernel/Interaction/` の純関数に置く(Simulator 無しで検証可能)。
- 新しい判定には「単調に動く入力列 → 出力列が跳ばない」テストを添える
  (`SidebarGesturePolicyTests` の軸ロックケースが実例)。
  カクつきは実機でしか「感じられない」が、不連続性はユニットテストで機械的に捕まえられる。

### P4. ライブ追従に withAnimation を混ぜない

- onChanged 中は素の代入で指へ直結する。暗黙/明示アニメーションは追従遅延と波打ちを生む。
- withAnimation(interactiveSpring 等)は onEnded の確定遷移(open/close への収束)だけ。

### P5. ドラッグの translation は、そのドラッグで動くビューの座標空間で測らない

DragGesture の `translation`・`startLocation` は、offset で動くビュー自身の座標空間(既定の `.local`)で
測ってはならない。

- offset 適用 → 座標空間が動く → 次フレームの translation が offset のぶん縮む → 出力 offset が戻る、の
  フィードバックループが毎フレーム振動(進む→戻るの2周期)を生む。
- translation・startLocation は offset を持たない祖先に置いた named 空間で測る。実装は DragGesture の
  `coordinateSpace: .named(...)` と、その空間を定義する `.coordinateSpace(name:)` を **offset より外側**の
  ビューへ付けること(swift-mcp-app では GeometryReader 直下の ZStack に置き、`.offset(x:)` は内側の
  NavigationStack だけが持つ)。
- 帯判定など Y 座標の突き合わせ(gesture の startLocation.y と preference で測った frame の minY/maxY)は、
  測定側と gesture 側が同一 named 空間を参照し続ける限り不変(x のみの offset は Y 原点を変えない)。
- 症状は P1 の軸ロックと同じ「速い操作では正常・遅い操作でカクつく」。振幅≒速度×遅延。

## ボツ案(Why not)

- **毎フレーム判定にヒステリシスを足す案**(閾値に幅を持たせて反転を抑える): 反転頻度は
  減るが不連続性そのものは残り、閾値際でやはり跳ぶ。one-shot ロックの下位互換でしかない。
- **カクつきを実機 E2E で検出する案**: フレーム落ちの官能評価は自動化コストが高すぎる。
  P3 のとおり「不連続性」という機械的性質へ還元して単体テストで固定する方が安い。

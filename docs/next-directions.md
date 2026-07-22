# 次セッションの方向性(2026-07-23 第3版)

> **位置づけ:** セッション引き継ぎの正典。ここには最新状態、着手順、未完了タスクだけを置く。
> **更新ルール:** 計画は消さない。完了は打ち消し線 + ✅、状況変化は該当箇所へ
> `> **YYYY-MM-DD 更新:** ...`を積層する。時系列の生記録は`docs/log.md`へ追記する。
> **履歴:** 第2版までの完成計画、判断根拠、参照スタックは
> [`docs/archive/next-directions-v2-2026-07-23.md`](archive/next-directions-v2-2026-07-23.md)へ
> 内容を変えず退避した。詳細が必要なときだけ読む。

## セッション開始時の現在地(2026-07-23)

- **完成済み:** P0〜P4-DM、M1(サーバー管理)、M2(複数サーバー同時接続・無言自動接続・
  `slug__tool`逆ルーティング)。caldavとtdr-conciergeの同時接続、tdrの実tool-useとMCP App
  カード描画までSimulatorで確認済み。
- **検証基盤:** `make check`はSwift build/test/lintの高速gate、`make app`はSwiftUIを含むiOS全体build、
  `make verify`は両方を束ねたpush前の最終gate。`make hooks`でtrackedなpre-push hookを有効化すると、
  通常のmain pushだけ`make verify`が走る（意図的な`--no-verify`は非常口として維持）。
  baselineなしSwiftLint strict 0件、177 tests、generic iOS Simulator app buildまでgreen。
  iPhone 12 miniへのbuild/install/launchとプロセス生存も確認済み。Simulator操作は汎用
  `ios-simulator`、MCPHost固有検証はproject `ios-e2e-verify`を併用する。
- **lint整理:** 既存baselineを撤去し、UI・chat orchestration・AppsBridge・test suitesを
  責務別の型/ファイルへ分割した。閾値緩和で隠さず、意味的に正しいwire変換等だけ理由付きの
  最小例外とした。`make check`と`make app`で統合確認済み。
- **横gesture競合:** MCP App内のgraph/carousel/slider操作と履歴drawerが競合しないよう、閉状態の
  swipe-openをleading edge 24pt開始に限定した。☰での明示操作と、開状態のmain card上での
  swipe/tap-to-closeは維持する。
- **iOS agent harness:** OpenAI公式`build-ios-apps`、現行simctl+idb、XcodeBuildMCP hybridの
  正式評価を計画した。詳細な試験票と進捗は
  [`docs/ios-agent-harness-benchmark.md`](ios-agent-harness-benchmark.md)を正とする。予備調査を
  正式評価の成功根拠にしない。
- **credential方針:** 実password/API keyはagentが入力しない。ユーザーが用途と値を明示した
  disposable test credentialはagentが入力してよい。caldav OAuth E2Eの`changeme`は入力可。
- **次の着手順:** ①正式評価H-01/K-01のD blindを承認後に確定 ②差が出た試験だけB/Cを診断し、
  採用候補をmainが再検証 ③今回のUI修正の回帰と、通常チャット
  fullscreen・agenda/open-link・両server混在/toggle OFFの残E2Eを消化。harnessの採用判断なしに
  現行fallbackを削除しない。

<!-- session-head-end: SessionStartフックはここまでを常時注入する。以下は未完了タスクだけを置く。 -->

## 1. 直近の完了gate

- [x] ~~caldav方式のtracked pre-push hook、`make hooks`、`make verify: check app`を追加する。~~ ✅
  > **2026-07-23 更新:** mainの通常pushだけ最終gateを実行し、branch削除・feature pushはskipする。
  > hook分岐はstub makeで検証した。
- [x] ~~`make hooks`で配線し、実際の`make verify`（check + generic Simulator app build）を完走する。~~ ✅
  > **2026-07-23 更新:** `core.hooksPath=.githooks`を設定。177 tests / 18 suites、SwiftFormat
  > 0/112、SwiftLint 0 violations / 111 files、generic iOS Simulator `BUILD SUCCEEDED`を確認した。
- [x] ~~現在のdirtyを機能単位に棚卸しし、各変更の目的・未完了・必要なユーザー確認を列挙する。~~ ✅
- [x] ~~`make check`を通し、sandbox/toolchain起因の失敗と製品regressionを分ける。~~ ✅
- [x] ~~MCP Appの横操作とhost drawerの全画面swipe競合を解消する。~~ ✅
  > **2026-07-23 更新:** drawer-openをleading edge 24ptに限定。履歴閲覧中は無効化し、
  > WKWebView中央の横操作をhost gesture認識領域から外した。
  > **2026-07-23 実カード確認:** caldav todosカード中央の横swipe前後でscreenshot SHA-256が一致し、
  > 左端swipeだけdrawerが開いた。tdr-concierge `park_waits`も通常チャットから実呼出しできた。
- [x] ~~Simulatorでdirtyが触る主要経路を実操作し、semantic tree・画面・unified logで裏取りする。~~ ✅
  > **2026-07-23 更新:** 専用Simulator DでOAuth再接続、複数server、toggle OFF、実todos/agenda App、
  > 横gesture、fullscreen往復、カード内`tools/call`、作成時focusまでsemantic tree・screenshot・logを照合した。
- [x] ~~docsと実装の事実が一致した時点で、変更を意図単位のcommitへ分割する。~~ ✅
  > **2026-07-23 更新:** fullscreen応答順序修正とW-01/agenda実E2Eを正典・benchmark・logへ反映し、
  > `make verify` green後に独立commitとする。

## 2. iOS agent harness正式評価

詳細・prompt・合格条件・計測方法は
[`docs/ios-agent-harness-benchmark.md`](ios-agent-harness-benchmark.md)だけを更新する。本節にはgateだけ置く。

- [x] ~~Phase 0: 固定commit、隔離config、専用Simulator、caldav test fixture、成果物保存先を用意する。~~ ✅
  > **2026-07-23 更新:** `9d2c168` / clean、A〜D専用iPhone 17、test fixture `changeme`、
  > `/private/tmp/swift-mcp-app-ios-harness-9d2c168`を固定した。
- [x] ~~`make run`のbuild/install/launchを専用Simulator UDIDへ一貫して固定できるようにする。~~ ✅
  > **2026-07-23 更新:** `SIMULATOR_UDID`を明示できるようにし、名前指定が同名端末へ複数一致する
  > 場合は候補UDIDを表示して停止する。専用Simulator評価で日常用端末への誤配送を防ぐ。
  > 実走で無署名runがKeychain `-34018`を起こすことも確認し、runだけad-hoc署名へ戻した。
- [x] ~~現行A / hybrid DのMCP schema量とskill context量を同じ方法で採取する。~~ ✅
  > Dは36 tools / 225,990 bytes。stock Bのunpinned `@latest`は先行実行せず、差分診断時だけB/Cを扱う。
- [ ] `fork_turns=none`のsubagentへ同一promptを渡し、H-01/K-01/O-01/W-01/L-01/M-01をblind比較する。
  > **2026-07-23 更新:** AのH-01/K-01は合格。Dはlocal capability probeでK-01合格だが、正式blindは
  > repo文脈を外部`codex exec`へ送る経路の明示承認待ち。D担当subagentのCLI fallback結果は採点しない。
- [x] ~~OAuth O-01でagentが`changeme`を入力し、callback→tool call→再起動後の無言接続まで完走する。~~ ✅
  > **2026-07-23 main独立再実行:** Dでcallback、`get-current-time`成功、terminate/relaunch後の
  > browserなし無言接続（caldav 23 tools）を確認。正式blind各構成2回の比較gateは別途継続する。
- [ ] keyboard試験でASCII、日本語、backspace、全選択/置換を確認する。
- [ ] WKWebView試験で実カード内操作、tools/call往復、fullscreen、JS状態保持を確認する。
  > **2026-07-23 main独立再実行:** 実`list-todos`カードでcollection menuを開くと
  > `refresh-todos`/`list-calendars`が往復し、inline→fullscreen→inline後もmenuのopen状態を保持した。
  > main独立分は合格。正式A/B/D各2回の比較gateは継続する。
- [ ] main sessionがraw traceを採点し、採用候補のO-01/W-01を独立再実行する。
  > **2026-07-23 更新:** O-01とW-01のmain独立再実行は合格。構成間のraw trace採点は未完了。
- [ ] Claude Codeのrate limit解消後、同じ採用候補でH-01/O-01を再実行する。
- [ ] 採用判断後にgeneric知識をuser plugin、MCPHost固有知識を`ios-e2e-verify`へ反映する。

## 3. MCPHost残E2E(優先順)

- [x] ~~1チャット内でcaldav/tdr-concierge両serverのtoolを混在させ、結果が由来serverへ戻る。~~ ✅
  > **2026-07-23 更新:** 同一ターンでcaldav `get-current-time`とtdr-concierge `park_waits`を
  > 順に実行し、server名付きの2 tool stepと統合応答を確認した。
- [x] ~~server toggle OFFが次のnew chatのtool一覧へ反映される。~~ ✅
  > **2026-07-23 更新:** tdr-conciergeをOFF後のnew chatで`park_hours`を要求してもtool stepは
  > 生成されず、利用可能なtoolがない応答になることを確認。試験後はONへ復元した。
- [x] ~~通常チャットの⊕でfullscreen昇格し、右上ドリフトなし、scrollIntoView、keyboard自動表示を確認する。~~ ✅
  > **2026-07-23 更新:** 実todosカードで確認。旧実装は成功応答をreparent前に返し、遅延focus後の
  > 載せ替えでkeyboardがhideしていた。応答を実reparentまで待たせ、timeout/cancelはinlineへrollback。
  > 修正版は作成行がkeyboard accessory上へ可視化され、focusを安定維持。右上縮小ボタンのドリフトも無い。
- [ ] todosのcollection切替、agendaの色filter/追加/行色、inline menuのclipなしを確認する。
  > **2026-07-23 部分確認:** todos collection menuとagenda色filter menuはinlineでclipなし。
  > agendaの⊕はfullscreenの予定/リマインダーformを開き、終日既定ONを確認して未保存cancelした。
  > collection実切替、予定行色、保存往復は未確認。
- [ ] 会議「参加」open-link、C3/C4作成、終日保存、action-row、カード内部scroll消滅を確認する。
- [ ] Simulator標準カレンダー/リマインダーへCalDAV accountを追加し、URL/CONFERENCE等を裏取りする。

## 4. host未解決論点

- [x] ~~編集操作のfullscreen方針とView capability gateを確定する。~~ ✅
  > **2026-07-23 更新:** hostは編集意図を推測しない。done/undo/toggleはinline、rename/作成/form/
  > 一括編集はカードが編集セッション前にfullscreenを要求する。明示capabilityにfullscreenが無いViewの
  > 要求はcallback前にinline拒否し、未宣言Viewはspecの`if set`に従って互換維持する。
- [x] ~~合成tool名が64字を超える場合の検証/短縮方針を決める。~~ ✅
  > **2026-07-23 更新:** 64字以下の`slug__tool`は完全互換。超過時だけ37字prefix＋`__h`＋
  > SHA-256先頭24hex（96bit）で64字にし、明示`ToolRoute`で元slug/toolへ逆引きする。
  > 異routeが同じwire名へ衝突した場合は後勝ちせずfail-closed、legacy parse fallbackも維持する。
- [x] ~~ToolStepRowと履歴詳細でslugをserver表示名へ逆引きし、日本語名serverも区別できるようにする。~~ ✅
  > **2026-07-23 更新:** 実行時のserver表示名とhash短縮前tool名を`ToolCallStep`へadditive保存。
  > ライブ/履歴は保存値を優先し、rename前履歴は当時名、新chatは新名。旧JSONはslug/URLへfallbackする。
- [ ] TodosCardSpikeViewのhard-coded URLを低優先で除去する。
- [ ] local HTTP MCPを許可する必要性を決める。許可時はscheme検証だけでなくATSも扱う。
- [ ] composer側のtool pickerを設計し、server/tool単位の有効化と状態表示を集約する。
- [ ] reasoning表示、宣言型network permission、geolocationは将来sliceとして維持する。

## 5. caldavと連携する次slice

- [ ] fullscreenのリスト/月/日切替と月grid(合意済みagenda-views-v6)を実装・検証する。
- [ ] 日timeline(現在時刻線、重なり解決、終日chip帯)を実装・検証する。
- [ ] agenda echo pinが全collection取得から単一`calendarId`へcollapseする問題を直すか決める。
- [ ] 書き込み前human-in-the-loop確認カードを設計する。
- [ ] C6+C7 geocode/mapと監査LOW残件を処理する。

## 6. 棚卸し運用

- SessionStart hookはこのheadだけを注入し、マーカー以降の行数と更新block数を測る。
- カタログが150行または更新blockが8個を超えたら、完了した節を日付付きarchiveへ移す。
- archiveへ移した計画は削除扱いにしない。最新docから必ずリンクし、必要時だけ読む。
- 詳細な試験票・設計・調査結果は専用docへ置き、本docへ重複させない。
- 大きな節目ではheadの「完成済み・現在のdirty・次の着手順」を書き直す。

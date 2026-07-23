# 次の方向性（2026-07-23 第5版）

> **位置づけ:** セッション引き継ぎの正典。goal達成状況、未完了タスク、所有者、着手順だけを置く。
> 完了計画と判断の履歴は
> [第4版](archive/next-directions-v4-2026-07-23.md)、
> [第3版](archive/next-directions-v3-2026-07-23.md)、
> [第2版](archive/next-directions-v2-2026-07-23.md)を参照する。
> 状況変化は該当箇所へ `> **YYYY-MM-DD 更新:**` を積層し、生記録は `docs/log.md` へ追記する。

## Goal達成状況

| Goal | 状態 | 判定 |
| --- | --- | --- |
| Swift製の汎用MCP Apps host | **MVP達成** | OAuth、tool-use、WKWebView bridge、inline↔fullscreen、履歴、複数server、app-only隔離まで実装・E2E済み。P0〜P4-DMの履歴は第2版に保存 |
| 汎用ホストとしての中立性 | **MVP達成・拡張継続** | caldav固有解釈をhostへ入れず、definition・route・attributionを同じ集合から生成。将来のnetwork permission / geolocationは未実装 |
| SaaSへ差し替え可能な構造 | **準備達成** | LLM呼出しはServicesの中立protocolとOpenAI互換adapterへ集約。Workers proxy、metering、billingは授業外の将来実装 |
| 品質・再現可能なdelivery | **基盤達成** | `make verify`、baselineなしlint、tracked pre-push hook、明示Simulator UDID、実機build/install/launchを確立 |
| Claude Code / Codex共有harness | **基盤達成・parity継続** | instructions・project skill・hookはsymlink共有。Apple Xcode MCPは実働確認済み。Codex DesktopのOpenAI公式`build-ios-apps`はH-01/K-01 Pass。Claude parityだけ継続中 |
| 授業提出 | **技術MVP達成・提出物未確定** | repoは動作可能。正式rubric、プレゼン、CI要否は外部入力待ち |

## 現在のworking tree

- **実装clean / docs同期中:** 整理開始時点で`main`は`origin/main`と一致し、working treeはclean。
  履歴カードlive island・drawer gesture分離・tool route堅牢化は`0bcf864`、
  履歴revalidation gate/hint撤去は`bdb3e1b`、ゆっくりdrawer dragの軸ロック修正は
  `81ace79`としてcommit / push済み。現在の未commit差分は、この現状同期による
  `docs/next-directions.md`、`docs/log.md`、Simulator運用正典の追加だけ。
- **delivery gate解消済み:** `ChatHistoryRow`をcomponentsへ抽出してtype body lintを解消し、
  `InlineCardView`のSwift 6 captured-`self` / Sendable警告も構造修正した。
  delivery時の`make verify`は完走・警告grep 0件。gate撤去後は211 tests / 22 suites・lint 0、
  軸ロックには6件の回帰testを追加した。
- **履歴refreshの現行境界:** host固有のfail-closed gate/hintは全撤去した。
  履歴復元時の`sendInitialPayload`で保存済みtoolResultを無改変再pushし、鮮度判定と
  60秒超の背景revalidateはcaldav SWR（deploy `56551ac`）へ委ねる。
  `HistoricalCardRouting.swift`は保存カードの接続再解決という別責務なので残す。
- **残る実操作確認:** 専用Simulatorまたは実機で、ゆっくりdrawer dragの指追従、
  MCP App内横gestureとの隔離、履歴カードの復元直後の操作、60秒超カードの背景revalidateを確認する。
  > **2026-07-23 更新: ゆっくりdrawer dragは実機確認済み ✅。** 軸ロック(81ace79)後も残振動があり、
  > 実機録画のフレーム解析で「進む→約2フレーム遅れへ戻る」2系列交互振動を特定。第2根因は
  > DragGestureが.offsetで動くビュー自身の.local空間でtranslationを測る座標空間フィードバックで、
  > named空間をoffset外側のZStackへ移設して解消(`616e4e2`)。ユーザーがiPhone 12 mini実機で
  > 改善を確認した。原則P5としてdocs/design/07とrules/interaction.mdへ制定済み。
  > 残: MCP App内横gesture隔離・履歴カード即操作・60秒超SWR背景revalidateの実機確認。

## Codex固有調査

- [x] ~~Codex公式plugin / marketplace / cache / scopeを現行公式資料とローカル実測で照合する。~~ ✅
- [x] ~~OpenAI公式`build-ios-apps` 0.1.2（cache revision `d6169bef`）をglobal Codexへinstall / enableし、
  新規`codex exec` sessionで`ios-debugger-agent`をロードする。~~ ✅
- [x] ~~OpenAI公式stock `build-ios-apps`でH-01を実測し、固定版XcodeBuildMCP、simctl+idbと比較する。~~ ✅
  > **2026-07-23 更新:** 初回stock実行は`codex mcp list`に`xcodebuildmcp`がenabledで現れ、skillも
  > 読み込めたが、`npx -y xcodebuildmcp@latest`の初回取得が60秒無出力のまま終了コード130となり、
  > MCP toolsは公開されなかった。同時にCodexが`No space left on device`を報告し、Data volumeは
  > 100%・空き2.4 GiBだったため、plugin不合格ではなく**環境阻害 / No score**とする。
  > **2026-07-23 再更新:** 空き14 GiBへ復旧し、`xcodebuildmcp@latest` 2.6.2の取得を完走して再試験した。
  > server自体は約0.2秒で起動・initialize成功したが、stock設定は2.6.2で未知の`logging`を含み、44 tools / 約63,469 tokensの
  > `tools/list`となった。fresh Codexは30秒でtool schema取得timeoutし、必須tool 0件のためH-01開始不能。
  > **2026-07-23 再々更新:** 上記から互換性不合格と断定した判断を撤回する。同一command / args / envへ
  > `startup_timeout_sec=120`だけを加えたfresh sessionでは44 toolsが公開され、Harness Bへ
  > build / install / launch（56.8秒）、49要素のsemantic snapshot、screenshotまでfallbackなしで成功した。
  > macOS / Xcode許可promptも出なかった。確定した問題は既定30秒のstartup deadlineであり、schema量は相関まで。
  > CLIではplugin installed / enabledだが、起動済みCodex Desktopのplugin一覧と本taskのskill snapshotには未反映。
  > Desktop再起動後の新規taskで表示・stock実行を確認し、K-01後に採否を決める。
  > **2026-07-23 再々々更新:** Codex Desktopから`Build iOS Apps`を有効化し、現在sessionへplugin由来skill群と
  > `xcodebuildmcp`が公開された。Desktop未反映は解消。次はこのsessionでK-01を実行する。
- [x] ~~Codex DesktopのOpenAI公式`build-ios-apps`でK-01を実測し、semantic入力訂正を評価する。~~ ✅
  > **2026-07-23 更新:** stock pluginが現在taskで追加設定なしに起動し、Harness Bへのbuild / install / launch
  > （12.5秒）とK-01を完走した。日本語はclipboard + semantic Paste、誤URLはASCII入力、backspace、
  > Select All / Pasteで訂正し、blur時のvalidation出現・解消、キャンセル後の未保存を確認した。
  > `replaceExisting:true`は日本語IME下でも成功応答を返しつつ文字化けしたため、操作後snapshotの値検証を必須とする。
  > macOS / Xcode許可promptは0。clipboard用`xcrun simctl pbcopy`だけCodex sandbox許可が必要だった。
- [x] ~~Apple公式Xcode MCPを実接続し、X-01（window取得 + Issue Navigator）を確認する。~~ ✅
- [x] ~~agent Simulator操作の証拠階層と採用方針を確定する。~~ ✅

詳細と公式出典は
[`docs/codex-plugin-and-ios-agent-audit.md`](codex-plugin-and-ios-agent-audit.md)、
試験履歴は[`docs/ios-agent-harness-benchmark.md`](ios-agent-harness-benchmark.md)を正とする。
日常運用、pluginの役割、Codex非依存化の境界は
[`docs/ios-simulator-best-practices.md`](ios-simulator-best-practices.md)へ集約した。

<!-- session-head-end: SessionStartフックはここまでを常時注入する。以下は未完了タスクだけを置く。 -->

## Codex次session queue（公式plugin benchmark）

- H-01 / K-01のDesktop実測は完了。追加のbenchmark taskはない。
- delivery後、必要ならO-01 / W-01を公式pluginで各1回だけparity確認する。実credentialは扱わない。

## Fableへ渡す実装queue

1. **delivery後のSimulator / 実機E2Eを閉じる**
   > **2026-07-23 更新:** lint / Xcode warning修正、`make verify`、commit / pushは完了。
   > `main`は`origin/main`と同期済み。残るのは実操作4項目だけ。
   - [ ] drawerをゆっくりdragして、軸ロック後も指へ連続追従することを確認する。
   - [ ] MCP App内の横gestureがdrawerを露出させないことを確認する。
   - [ ] 復元した履歴カードが待機なしで即操作できることを確認する。
   - [ ] `generatedAt`から60秒超のカードが、表示を維持したまま背景revalidateすることを確認する。
2. ~~**caldavで履歴revalidationを完成させる** → **履歴revalidation gateを撤去する**(2026-07-23差し替え)~~ ✅
   > **2026-07-23 更新: 撤去完了。** 専用2ファイル削除+8ファイルの配線撤去(net -227行)。
   > 再push経路は`sendInitialPayload`に残し、`historyRestorePushesSavedToolResult`テストで
   > 「tool-input→tool-result順・structuredContent無改変配送」を固定(caldav SWRの発火条件)。
   > 211 tests / 22 suites・lint 0。残: 履歴カード即操作+60秒超の背景revalidateのE2E実機確認。
   - 前提が崩れた: caldav側はhint対応不要と裁定し、SWR(generatedAt 60秒判定)を本番実装済み(56551ac)。
   - `HistoricalCardRevalidationGate.swift`と`Kernel/AppsProtocol/HistoricalRevalidation.swift`を全撤去し、
     `sendInitialPayload`は素のstructuredContent送信へ簡素化する。
   - `AppsBridgePassthroughDispatcher`のtools/call観測(gate専用の存在理由)と、
     InlineCardView / HistoryDetailView / InlineCardPresentation / AppsBridgeSessionの
     `requiresHistoricalRevalidation`配線・overlay UIを除去する。`HistoricalCardRouting.swift`は残す。
   - `AppsProtocolTests`のgateテストを削除し、履歴復元で保存済みtoolResultが再pushされること
     (caldavのSWR発火条件)をテストで固定する。
   - E2E: 履歴カードが即操作可能で、60秒超の古いカードは背景revalidateされることをcaldav本番で確認する。
3. **再現可能なnative UI回帰層を追加する**
   - `MCPHostUITests`と安定したaccessibility identifierを追加する。
   - connection validation、drawer/context menu、reparent spike、履歴復元/SWR発火条件から固定する。
   - live OAuth / caldav本番はpre-push必須にせず、project E2Eへ残す。
4. **共有harness sourceを中立化する**（`gigun-dev/claude-code`へscopeを移してから）
   - generic `ios-simulator`を明示UDID、bounded poll、実行時scaleへ直す。
   - 引数なし`idb connect`を現行CLIに合わせ、idb / companionのversion、古いsocket、
     Xcode 26.4互換性を隔離環境で検証する。現在の`idb list-targets`は標準fallbackとして未ready。
   - `ios-device-build`の`~/.claude/...`ハードコードを実行中skillからの相対pathへ直す。
   - 触るpluginから`.codex-plugin/plugin.json`とroot `.mcp.json`を追加し、隔離installで検証する。
   - 固定版XcodeBuildMCPのcustom workflowをbuild/runと最小UI操作へ絞り、stock 44 tools、
     既存D 36 toolsと同じtokenizerでschema token数を比較する。
   - H-01 / K-01 / O-01を`build-ios-apps`なしの隔離環境で再実行し、Codexなしでもdelivery可能と固定する。
5. **Composer tool picker**
   - [design/06](design/06-composer-tool-picker.md)の4判断をユーザー合意後に実装する。
   - chat単位freeze、stable `ToolKey`、atomic surface、44pt/VoiceOver、session保持をtestする。
6. **caldav残E2Eとagenda**
   - 予定行色、filter、追加・終日保存、action-row、open-link、C3/C4を確認する。
   - fullscreen月grid、日timeline、echo pinの`calendarId`問題を順に扱う。
7. ~~**ツール許可ゲート(R4・caldav申し送り採択)**~~ ✅
   > **2026-07-23 更新: 実装完了(67a7b3d)。** Kernel純関数(緩和はreadOnly申告のみ)+
   > UserDefaults Store(serverURL×originalToolName)+ Runnerゲート(Features注入の確認フック・
   > 並行callキュー)+ 確認ダイアログ。カード発はdenyのみ尊重(直前タップへの再確認は二重確認)。
   > annotationsはOpenAI wireへ非送出。232 tests。残: 設定画面の決定一覧/リセットUI(次slice)、
   > 実機での確認ダイアログ触感、caldav実annotationsとのE2E。実機deployは端末再接続待ち。
   - 影響面調査済み: annotationsは現状一切パースしていない。`ToolConversion.swift`でMCP
     `tool.annotations`(readOnlyHint/destructiveHint等)を`ToolDefinition`へ保持する所から始める。
   - 挿入点は`ToolCallRunner.executeValid`の`callTool`直前。カード発は`AppsServerProxy.callTool`側。
   - UXはclaude.aiカスタムコネクタと同じ境界(常に許可/毎回確認(既定)/拒否)。queue 5のpickerと
     surface設計を揃える。annotationsはuntrusted hintなので既定は確認側に倒す。
8. **後続設計**
   - claude.ai iOSでcaldavカードのみ描画失敗する問題の切り分け(下記「caldavセッションからの申し送り」後注)。
   - fullscreen UX再確認: キーボード閉じはカード側根因修正済み(caldav ce7d5aa)なので再現確認から。
     カード成長起点の自動スクロール追従(`ChatBodyView`のscrollTo群)はmodeling/15 §B採用に伴い
     削減方向で見直す(カード発のスクロール要求機構はもともと存在しない)。
   - 観測: クラッシュのみSentry(SPM sentry-cocoa)、行動イベントはcaldav telemetry v1が真実源。
     セッションIDを`_meta["gigun.dev/session"]`で透過しSentry scopeへ同じIDを置く。
   - 書込前HITL確認カード、C6+C7 geocode/map、宣言型network permission、geolocation。

## 採用済みiOS agent harness

1. `make check/app/verify` — fast gate
2. Apple Xcode MCP — Apple docs、Xcode build/test/log、Issue Navigator、file diagnostics、Preview
   （runtime UI操作とlint / pre-push gateの代替には使わない）
3. source-controlled XCUIAutomation — 安定したnative UI回帰
4. **固定版**XcodeBuildMCP CLI / 最小workflow — client非依存の再現可能な探索E2E
5. `ios-simulator`（simctl + idb）— 修繕後に使う明示UDID、accessibility-firstの汎用fallback
6. OpenAI公式`build-ios-apps` — Codex Desktopで探索を始めやすくするoptional adapter
7. project `ios-e2e-verify` — OAuth、caldav、WKWebView、JS状態、unified log
8. 実機 — 通常のiOS変更後はbuild/install/launchまで行う

OpenAI公式stock `build-ios-apps`はCodex Desktopの探索E2Eへ**条件付き採用**する。H-01/K-01はPassしたが、
`@latest`の浮動依存、0.1.2 skillのtool名drift、CLI既定30秒のstartup timeout、IME下での
`replaceExisting:true`成功応答と実値の不一致は残る。恒久回帰はXCUIAutomation、再現可能な診断は固定版を使い、
plugin操作後はsemantic snapshotで値を再確認する。pluginは必須dependencyではなく、Codex Marketplace、
taskへの自動公開、Desktop内の承認・会話統合というUXだけをprovider固有層に置く。build、run、UI操作、log、
debug、OAuth / WKWebView E2Eは固定版CLI / MCP、simctl、XCUIAutomation、project skillで代替する。

## ユーザー・外部待ち

- pickerの4 UX判断を最終確定する。
- caldav本番へ明示名fixtureを作成→確認→削除すること、および専用SimulatorへCalDAV accountを
  追加することは、実行直前に対象を再確認する。
- 授業のrubric、提出形式、プレゼン期限が分かり次第、presentation / CIをscopeする。
- Claude Codeのrate limit解消後、採用済みharnessのH-01/O-01だけprovider parity確認する。

## 完了条件

- 各sliceは実装、対応test、必要な専用Simulator E2E、`make verify`、実機再deploy、docs/log、
  commit / pushまでを一単位とする。
- agentの探索操作だけを恒久回帰とみなさない。安定したnative flowはXCUIAutomationへ昇格する。
- 実credentialは入力しない。ユーザーが値と用途を明示したdisposable fixtureだけを扱う。

## caldav セッションからの申し送り(2026-07-23・caldav 側 Claude Code セッションが追記。コミットは本セッションに委ねる)

caldav 側の設計転換・実測に伴う swift-mcp-app への提案・依頼。根拠の詳細は
caldav リポジトリ docs/next-directions.md の 2026-07-23 更新ブロック群と docs/modeling/15。

1. **履歴カード revalidation ゲート(fail-closed)の撤去を推奨。**
   - claude.ai web の履歴復元は楽観復元と実測確認(履歴を複数遡っても tool call ほぼゼロ・
     focus 時のみカード自身の refetch が発火。caldav 本番ログ 2026-07-23)。
   - hint(dev.gigun.mcphost/historical-revalidation)はホスト固有プロトコルで、
     知らないサードパーティカードは履歴上で永久操作不能になる=汎用ホストとして不成立。
   - RFC 5861(stale-while-revalidate)の設計思想(stale を出して背景検証・エラー時こそ
     stale)と逆。ext-apps 仕様にこの種の gate/hint を標準化する足場も無い。
   - caldav 側は代替として view model に generatedAt を追加し「60秒超の古い push は
     カード自身が背景 revalidate」する SWR を実装済み(deploy 56551ac)。ホストの責務は
     素の focus/visibility イベントを WebView に届けることだけ(無くても成立する)。
2. **ツール許可ゲート(R4)**: ToolCallRunner.executeValid の手前に annotations 駆動の
   per-tool 許可(常に許可/毎回確認/拒否・claude.ai カスタムコネクタと同じ境界モデル)。
   caldav は全23+ツールに annotations(readOnlyHint/destructiveHint 等)を申告済み。
3. **fullscreen UX**: キーボードが勝手に閉じる問題はカード側根因(シート表示中の破壊的
   renderAll)と判明し caldav 側で修正済み(ce7d5aa)。swift 側は再現確認から。
   スクロール過剰発火は「カードはプログラム的スクロールを要求しない」原則(caldav
   modeling/15 §B)採用後は発火機構ごと削る方向を推奨。HostContext.safeAreaInsets は
   ホストクローム分を含めて正道申告する(カードは申告を第一優先で読む実装済み)。
4. **観測**: クラッシュは Sentry(SPM sentry-cocoa・privacy manifest)のみ導入を推奨。
   行動イベントはサーバー(caldav telemetry v1)が真実源なのでクライアントで二重計測
   しない。相関は tools/call の _meta["gigun.dev/session"] にセッション ID を透過し、
   同じ ID を Sentry scope へ。

> **2026-07-23 後注(本セッション裁定):** 上記1〜4を根拠レビュー(modeling/15・実測ログ・
> 実装コミット56551ac/ce7d5aa・Swift側影響面調査)の上ですべて採択した。1はqueue 2へ差し替え、
> 2はqueue 7、3・4はqueue 8へ反映済み。
>
> **別件・claude.ai iOSのcaldavカード描画失敗(要切り分け):** claude.ai iOSアプリで
> caldavカードだけ「MCPアプリの読み込みに失敗しました サーバーに接続できません」となる。
> 事実関係: ①同端末・同会話でTDR Wait Timesカードは描画される=モバイル全面未対応ではない
> ②web/Desktopではcaldavも描画される=契約自体は有効 ③失敗時、caldav Workersログに
> resources/read相当の到達なし・`Claude-User` UAのtools/callは全成功 ④近接時刻に
> `401 invalid_token`が単発2回(23:46:40/23:54:40 UTC・UA未記録)。
> 有力仮説: (a) iOSアプリのカードレンダラーがOAuth必須サーバーでのresource取得に
> token を正しく載せない/失効tokenを使う(TDRは認証構成が異なり成立する説)、
> (b) caldavのUIリソースサイズ(bundle約1MB超)がモバイル側の上限に当たる。
> 次の一手: TDR側の認証方式・resourceサイズを caldav と突き合わせ、caldav側で
> 最小HTMLのテスト用app resourceを1つ生やしてiOSで描画可否を見る(サイズ説と認証説を分離)。

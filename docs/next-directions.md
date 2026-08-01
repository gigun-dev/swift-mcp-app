# 次の方向性（2026-07-24 第6版）

> **位置づけ:** セッション引き継ぎの正典。goal達成状況、未完了タスク、所有者、着手順だけを置く。
> 完了計画と判断の履歴は
> [第5版](archive/next-directions-v5-2026-07-24.md)、
> [第4版](archive/next-directions-v4-2026-07-23.md)、
> [第3版](archive/next-directions-v3-2026-07-23.md)、
> [第2版](archive/next-directions-v2-2026-07-23.md)を参照する。
> 状況変化は該当箇所へ `> **YYYY-MM-DD 更新:**` を積層し、生記録は `docs/log.md` へ追記する。
> **棚卸方針:** 完了 queue は打ち消し線+✅ で1〜2行に畳んでから archive へ移す。判断の経緯・
> ボツ案・実測ログは archive と log.md に残す(消さない)。

## Goal達成状況

| Goal | 状態 | 判定 |
| --- | --- | --- |
| Swift製の汎用MCP Apps host | **MVP達成** | OAuth、tool-use、WKWebView bridge、inline↔fullscreen、履歴、複数server、app-only隔離まで実装・E2E済み。履歴カード正しさ+接続ライフサイクル4層防御まで到達 |
| 汎用ホストとしての中立性 | **MVP達成・拡張継続** | caldav固有解釈をhostへ入れず、definition・route・attribution・観測イベント名を中立集合から生成。将来のnetwork permission / geolocationは未実装 |
| SaaSへ差し替え可能な構造 | **準備達成** | LLM呼出しはServicesの中立protocolとOpenAI互換adapterへ集約。Workers proxy、metering、billingは授業外の将来実装 |
| 品質・再現可能なdelivery | **基盤達成** | `make verify`、baselineなしlint、tracked pre-push hook、明示Simulator UDID、実機build/install/launch、simulator-operator subagent委譲を確立 |
| Claude Code / Codex共有harness | **基盤達成・parity継続** | instructions・project skill・hookはsymlink共有。Apple Xcode MCPは実働確認済み。Codex DesktopのOpenAI公式`build-ios-apps`はH-01/K-01 Pass。Claude parityだけ継続中 |
| 授業提出 | **技術MVP達成・提出物未確定** | repoは動作可能。正式rubric、プレゼン、CI要否は外部入力待ち |

## 現在地(2026-07-24)

- **実装clean / `main`==`origin/main`。** 直近の到達点:
  - **接続ライフサイクル4層防御そろった** — 層1自動refresh(swift-sdk・queue 8)/層2 in-place再認可
    (needsAuthバッジ+「認証して接続」・f13a3c7)/層3冪等add(serverID温存・queue 10 `514b01b`)/
    層4履歴カードURL束縛(serverURLフォールバック・queue 9 c27dd10)。
  - **履歴カードの正しさ** — プレースホルダ・バグ根因(再追加でserverID変化→provenance孤児化)を
    Kernel純関数HistoricalCardResolverの多段解決で解消。鮮度ギャップは履歴再訪時のtool-result
    再pushで解消(SWR発火条件を満たす)。**E2E裏取り済み**(下記「実操作チェックリスト」)。
  - **クライアント観測(queue 11・e38a2c1)** — KernelにTelemetryPort抽象+CardResolutionTelemetry
    (outcome/reason)、ServicesにOSLogTelemetry。カード解決点で`card.resolve`を1回発火。
    `log show --predicate 'subsystem=="dev.gigun.mcphost" && category=="card.resolve"'`で
    「なぜplaceholderか」が1行で見える(今後の再追加でreason=server-url-mismatchが出れば回帰)。
- **完了 queue(archive済み・経緯はv5/log.md):** 2(履歴gate撤去)/7(ツール許可ゲートR4)/
  8(OAuthトークンライフサイクル)/9(履歴カード正しさ)/10(冪等add)/11(クライアント観測)。
- **Codex固有調査:** H-01/K-01のDesktop実測完了・全項目✅(経緯はv5)。詳細と出典は
  [`codex-plugin-and-ios-agent-audit.md`](codex-plugin-and-ios-agent-audit.md)、
  試験履歴は[`ios-agent-harness-benchmark.md`](ios-agent-harness-benchmark.md)、
  日常運用は[`ios-simulator-best-practices.md`](ios-simulator-best-practices.md)を正とする。
- **Simulator操作は`.claude/agents/simulator-operator.md`(sonnet)へ委譲**(mainでスクショ往復しない)。
  > **2026-07-24 追加: ツール許可UI(design/09)完了 ✅** — per-MCPサーバーのツール許可を設定/確認できる
  > 機能。許可判定のベスプラ準拠(緩和は未保存の既定層のみ・明示決定優先・trusted&&readOnly&&closed-world)+
  > ランタイム確認のdetentセミモーダル化。設定UIはユーザーFBで最終的に「コネクタ詳細にツール一覧を
  > インライン(有効/状態と同階層)+ MCP単位の一括メニュー(すべて許可/確認/ブロック/既定に戻す)+
  > 個別ツール詳細のみプッシュ」へ(中間プッシュ廃止・claude.aiと同階層)。実機E2E A/B/C/D全PASS +
  > iPhone 12 mini install済み・ユーザー確認OK。commit 65987c0〜3cdc073。正典 docs/design/09。
  > 残: deny ツールのLLM一覧除外(design/09未決・queue5と絡む)。UI方針はmemory記録。

<!-- session-head-end: SessionStartフックはここまでを常時注入する。以下は未完了タスクだけを置く。 -->

## 実操作チェックリスト(実機/専用Simulator)

- [x] ~~ゆっくりdrawer dragの連続追従~~ ✅ 2根因(軸ロック81ace79・座標空間616e4e2)修正後にユーザー確認。
- [x] ~~MCP App内横gestureがdrawerを露出させない~~ ✅ 端x≈18ptのみiOS edge-swipeと衝突(仕様)。
- [x] ~~復元履歴カードが待機なしで即操作~~ ✅ update-todo実tools/call(ms=672)まで確認。
- [x] ~~R4許可ゲート3経路(create=確認/list=即実行/delete=destructive警告)~~ ✅ Harness A実画面+ログ。
- [x] ~~履歴再訪の鮮度再push・serverID変更耐性~~ ✅ 2026-07-24・c27dd10: 再訪でプレースホルダ0回・
  tool-result 1回flush(多重送出なし)、caldav削除→再追加で新serverIDでもライブ再描画(層4奏功)。
- [x] ~~**queue 10のE2E裏取り(層3冪等add・層2再認可)**~~ ✅ 2026-07-24・build 514b01b(HEAD 9f17953)・
  Harness A install: 層3=同一URL/末尾スラッシュ違い再addでエントリ1件のまま・「既存を再利用(冪等add)」
  ログのみ(新規append notice ゼロ)・再訪カードcard.resolve reason=server-id-match。層2=自然失効の
  needsAuth→「認証して接続」→ready復帰・serverID保持。todo状態不変更。
  > **副次観察(要小修正候補):** 冪等再利用時に既存エントリの表示名が入力名で上書きされる
  > (caldav→caldav-slash)。再追加は通常「認証やり直し」で改名意図が薄い(改名は編集UIあり)ため、
  > 再利用時はname温存の方が驚きが少ない。次の小slice候補。
- [ ] delete-todo応答完了後にUIがスピナーのまま固まる事象(2026-07-23に1回・tools/callは完了済み・
  再起動で復旧・再現条件未特定)。要ウォッチ。
- [x] ~~**冪等add時のname上書きを温存へ(小修正)**~~ ✅ `39c2658`: 再利用時は既存name温存(改名は編集UIに
  一本化)。テスト reAddPreservesExistingName へ反転。
- [ ] caldav本番のlist-todosが単発60sタイムアウト(2026-07-24 E2E・Workerコールドスタート等)。権限機能とは
  無関係だが、初回接続直後のツール呼びの遅延として要ウォッチ(頻発ならcaldav側と要相談)。

## Fableへ渡す実装queue(未完了)

1. **再現可能なnative UI回帰層を追加する** — B0 土台完了 ✅ `44db6f7`(MCPHostUITestsターゲット+
   MCPHostスキームtest相乗り+`make uitest`(SIMULATOR_UDID必須・ONLY_ACTIVE_ARCH=YES・pre-push非対象)+
   home.root identifier+スモーク1本 green)。残: **B1**=決定論で回るflow(設定シート開閉/サーバー追加
   フォームvalidation/サイドバー`MCPHOST_SIDEBAR_OPEN`)、**B2**=今回のツール許可flowを回帰する偽接続
   ハーネス(ダミーReadyConnection注入・実caldav不要)。identifierは触るflowごとに付与。
   - connection validation、drawer/context menu、reparent spike、履歴復元/SWR発火条件から固定する。
   - live OAuth / caldav本番はpre-push必須にせず、project E2Eへ残す。
2. **共有harness sourceを中立化する**(`gigun-dev/claude-code`へscopeを移してから)
   - generic `ios-simulator`を明示UDID、bounded poll、実行時scaleへ直す。
   - ~~引数なし`idb connect`を現行CLIに合わせ~~ ✅ **2026-07-31 修正済み**。
     `idb connect <UDID>`(UDID明示)が正で、引数なしはアタッチされず
     `idb list-targets`が`No Companion Connected`のまま無反応になる、と実地確認。
     SKILL.mdへ訂正ブロックとして記載。**generic `ios-simulator`は「要修繕」から
     「実地で通した経路」へ格上げしてよい**(iPhone 17 / iOS 26.4 で通し検証)。
   - **同時に踏んだ罠3件をSKILL.mdの「★ハマりどころ」へ追記済み**(2026-07-31):
     ①**日本語ロケールで`idb ui text`のASCII入力がローマ字→かな変換で壊れる**
     (`"caldav.gigun-dev.workers.dev"`→`"cあlだv。ぎぐんーでv。…"`。エラーにならないので気づけない)。
     回避は`idb ui key <UDID> 57`(Caps Lock=英語入力トグル・ロックなので後続フィールドにも持続)。
     ハードウェアキーボード接続中はソフトキーボードが出ないので🌐地球儀キー経路は使えない。
     ②スクショ出力先は`$HOME`配下(`/tmp`はsandboxが弾き"volume is read only")。
     ③`idb ui describe-all`はJSONLではなく入れ子JSON配列(1行1要素で読むと落ちる。再帰walker必須)。
   - 残: idb / companionのversion差、古いsocket、Xcode 26.4互換性の隔離環境検証。
   - `ios-device-build`の`~/.claude/...`ハードコードを実行中skillからの相対pathへ直す。
   - 触るpluginから`.codex-plugin/plugin.json`とroot `.mcp.json`を追加し、隔離installで検証する。
   - H-01 / K-01 / O-01を`build-ios-apps`なしの隔離環境で再実行し、Codexなしでもdelivery可能と固定する。
3. **Composer tool picker**
   - [design/06](design/06-composer-tool-picker.md)の4判断をユーザー合意後に実装する。
   - chat単位freeze、stable `ToolKey`、atomic surface、44pt/VoiceOver、session保持をtestする。
4. **caldav残E2Eとagenda**
   - 予定行色、filter、追加・終日保存、action-row、open-link、C3/C4を確認する。
   - fullscreen月grid、日timeline、echo pinの`calendarId`問題を順に扱う。

## 後続設計・観測拡張(次slice判断待ち)

- **観測の次slice論点(queue 11で残した2点):** (a) TraceSink(tool-useループ用)とTelemetryPortの
  二重化を一本化するか別seam維持か。(b) session相関IDの寿命(現状per-launch UUID→チャットセッション
  単位 or W3C traceparentへ寄せるか)。どちらも「相関を本格化するとき」に決める。
- **traceparent `_meta`伝播:** session IDを`_meta["gigun.dev/session"]`でtools/callへ透過し、
  caldav Analytics Engineと同IDでJOIN(キーはtraceparent互換)。今回はスコープ外にした拡張。
- **Sentry(クラッシュのみ):** SPM sentry-cocoa・privacy manifest。行動イベントは二重計測せず
  caldav telemetry v1が真実源。Sentry scopeへ同じsession IDを置く(caldav申し送り4・採択済み)。
- **fullscreen UX再確認:** キーボード閉じはカード側根因修正済み(caldav ce7d5aa)なので再現確認から。
  カード成長起点の自動スクロール追従(`ChatBodyView`のscrollTo群)はmodeling/15 §B採用に伴い
  削減方向で見直す(カード発のスクロール要求機構はもともと存在しない)。
- 書込前HITL確認カード、C6+C7 geocode/map、宣言型network permission、geolocation。

## 外部起票・切り分け待ち

- **Anthropicへのバグ報告(未起票):** claude.ai iOSのカード描画パスがaccess token失効後に
  リフレッシュせず401 invalid_tokenを「サーバーに接続できません」と表示する件。台帳+英文ドラフトは
  [external-issues/claude-ai-ios-card-token-refresh.md](external-issues/claude-ai-ios-card-token-refresh.md)。
  次の自然なtoken失効時に3点再現(diag-card失敗→再認可→成功)を採取してから起票する。
  req_011CdK4EGbphwRXcNpmLbsPy。
- **別件・claude.ai iOSのcaldavカード描画失敗(要切り分け):** TDRカードは描画されcaldavだけ失敗する件。
  上の認証説(401)で大筋確定したが、bundle約1MB超のサイズ説を完全排除できていない。
  次の一手: caldav側に最小HTMLのテスト用app resourceを1つ生やしてiOS描画可否を見る(サイズ説と認証説の分離)。
  ※diag-card(1243B)は再作成後iOSで描画成功済み=サイズ説はほぼ棄却済みだが、caldav実カードでの再確認は未。

## 採用済みiOS agent harness

1. `make check/app/verify` — fast gate
2. Apple Xcode MCP — Apple docs、Xcode build/test/log、Issue Navigator、file diagnostics、Preview
   （runtime UI操作とlint / pre-push gateの代替には使わない）
3. source-controlled XCUIAutomation — 安定したnative UI回帰
4. **固定版**XcodeBuildMCP CLI / 最小workflow — client非依存の再現可能な探索E2E
5. `ios-simulator`（simctl + idb）— **user scopeの共有skillが原典**。明示UDID、
   accessibility-firstの汎用fallback。**2026-07-31に`idb connect <UDID>`修正+ハマりどころ3件
   追記で実地通し済み**なので「修繕後に使う」ではなく**今使える**。
   実体は`gigun-dev/claude-code/plugins/ios-skills/skills/ios-simulator/SKILL.md`。
   **Simulator CLI操作の汎用知識はここへ書く**(project docsに重複させない)。
6. OpenAI公式`build-ios-apps` — Codex Desktopで探索を始めやすくするoptional adapter
7. project `ios-e2e-verify` — OAuth、caldav、WKWebView、JS状態、unified log
8. simulator-operator subagent(sonnet)— 画面操作の委譲先(mainはスクショで汚さない)
9. 実機 — 通常のiOS変更後はbuild/install/launchまで行う

OpenAI公式stock `build-ios-apps`はCodex Desktopの探索E2Eへ**条件付き採用**する(H-01/K-01 Pass)。
残る注意: `@latest`浮動依存、0.1.2 skillのtool名drift、CLI既定30秒startup timeout、IME下での
`replaceExisting:true`成功応答と実値の不一致。恒久回帰はXCUIAutomation、再現可能な診断は固定版を使い、
plugin操作後はsemantic snapshotで値を再確認する。build/run/UI操作/log/debug/OAuth/WKWebView E2Eは
固定版CLI / MCP、simctl、XCUIAutomation、project skillで代替でき、pluginは必須dependencyではない。

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

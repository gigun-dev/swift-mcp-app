# 次の方向性（2026-07-23 第4版）

> **位置づけ:** セッション引き継ぎの正典。ここには現在地、着手順、未完了タスクだけを置く。
> **更新ルール:** 完了は打ち消し線 + ✅、状況変化は該当箇所へ`> **YYYY-MM-DD 更新:**`を
> 積層し、時系列の生記録は`docs/log.md`へ追記する。棚卸し時も完了計画を削除せず、版全体を
> 日付付きarchiveへ退避してこの文書から辿れるようにする。
> **履歴:** 第3版の全文は
> [`docs/archive/next-directions-v3-2026-07-23.md`](archive/next-directions-v3-2026-07-23.md)、
> 第2版までの完成計画・判断根拠・参照スタックは
> [`docs/archive/next-directions-v2-2026-07-23.md`](archive/next-directions-v2-2026-07-23.md)。

## セッション開始時の現在地（2026-07-23）

- **製品基盤:** MCP Apps host、OpenAI互換tool-use、OAuth、複数server、履歴、inline↔fullscreen、
  app-only tool隔離まで実装済み。モデルへ広告したdefinition・明示route・カード帰属は同じ集合から生成し、
  未広告toolはChatHomeのexecutorでfail-closedにする。カード内部のapp-only呼出しだけは維持する。
- **検証基盤:** `make check`はKernel/Servicesのbuild・206 tests / 21 suites・baselineなしlint、
  `make app`はSwiftUIを含むSimulator build、`make verify`は両方を束ねる。tracked pre-push hookは通常の
  main pushで`make verify`を実行する。複数端末では`make run SIMULATOR_UDID=<UDID>`を必須とする。
- **Simulator skill:** 汎用CLI操作は`ios-simulator`、MCPHost固有のbuild・認証・ログ・カードE2Eは
  project `ios-e2e-verify`を使い分ける。どちらも必要で、一方へ統合しない。
- **横操作の所有権:** drawerのopen gestureは物理左端24pt、close gestureは開状態で露出する
  main cardだけに限定する。中央WKWebViewとsidebar/listにはhost横gestureを置かず、MCP App内の
  横操作はWKWebViewが所有する。履歴管理は標準context menu（pin・rename・確認付きdelete）へ集約する。
- **現在の主要slice:** composer tool picker、iOS agent harness正式比較、caldav本番を使う残E2E。
- **承認待ち:** pickerの4 UX判断、外部`codex exec`へrepo文脈を渡すblind、固定版stock Bの実行、
  caldav本番の一時書込と専用SimulatorへのCalDAV account追加。実credentialは入力せず、ユーザーが
  用途と値を明示したdisposable fixture（現状`changeme`）だけを使う。
- **外部待ち:** Claude Code parityはrate limit解消後に再開する。harnessの採用判断前に現行fallbackを
  削除しない。
- **着手順:** ①picker方針の合意→実装・回帰 ②承認後にD blindと固定版B→差がある試験だけC
  ③caldav書込承認後にagenda/open-link/標準Calendar・Reminders往復 ④raw trace採点・採用判断・
  generic/pluginとproject skillへの反映 ⑤Claude parity。

<!-- session-head-end: SessionStartフックはここまでを常時注入する。以下は未完了タスクだけを置く。 -->

## 1. ユーザー合意・承認gate

- [ ] [`docs/design/06-composer-tool-picker.md`](design/06-composer-tool-picker.md)の推奨4点を合意する。
  chat単位freeze、発話後の変更はnew chat確認、app-onlyはread-only補助表示、履歴へtool snapshot保存。
- [ ] Dの正式blind用に、repo contextを外部`codex exec`へ渡すことを承認する。
- [ ] unpinnedな`@latest`を避け、解決した固定versionでstock Bを実行することを承認する。
- [ ] caldav本番へ明示名のテスト予定・リマインダーを作成→確認→削除し、専用Simulatorへ
  CalDAV accountを追加することを承認する。日常用Simulatorは使わない。

## 2. Composer tool picker

- [ ] 合意後、設定の永続「自動接続」とcomposerのchat単位「このチャットで使用」を分離する。
- [ ] stable keyを`ToolKey(serverID, originalToolName)`とし、server renameや64字wire短縮に耐える。
- [ ] 選択集合からLLM definition・executor route・UI attribution・表示名を原子的に生成する。
- [ ] picker sheet、44pt hit area、VoiceOver、接続状態、0件、tool増減、draft/session保持を実装する。
- [ ] 純関数・統合testと専用Simulator回帰で、未広告拒否とapp-only card call維持を証明する。

## 3. iOS agent harness正式評価

試験票、prompt、固定環境、合格条件、artifact、raw結果の正は
[`docs/ios-agent-harness-benchmark.md`](ios-agent-harness-benchmark.md)。予備調査やmain独立再実行を
構成間blind比較の代用にしない。

- [ ] 承認後、未完了のD H-01/K-01と、A/B/DのO-01・W-01・L-01・M-01を規定回数blind実行する。
  AのH-01/K-01（ASCII、日本語、backspace、全選択/置換を含む）は完走済みで再実行しない。
- [ ] Bの失敗が依存version由来の場合だけCで該当試験を診断する。
- [ ] main sessionがraw traceを採点し、採用候補のO-01/W-01を独立再実行する。
- [ ] 採用結果を確定し、generic知識はuser plugin、MCPHost固有知識は`ios-e2e-verify`へ反映する。
- [ ] Claude Codeのrate limit解消後、同じ候補でH-01/O-01とprovider非依存性を再検証する。

## 4. caldav連携の残E2E

- [ ] agendaの予定行色、色filter、追加・終日保存、action-row、カード内部scroll消滅を確認する。
- [ ] 会議「参加」のopen-linkとC3/C4作成を確認する。
- [ ] 専用Simulatorの標準Calendar/RemindersへCalDAV accountを追加し、URL/CONFERENCE等を裏取る。
- [ ] 本番書込を行う各試験は明示名fixtureを作成し、確認後に削除して残存物がないことを確かめる。

## 5. 後続slice（順序を維持）

- [ ] fullscreenのリスト/月/日切替と月grid（合意済みagenda-views-v6）を実装・検証する。
- [ ] 日timeline（現在時刻線、重なり解決、終日chip帯）を実装・検証する。
- [ ] agenda echo pinが全collection取得から単一`calendarId`へcollapseする問題を直すか決める。
- [ ] 書き込み前human-in-the-loop確認カードを設計する。
- [ ] C6+C7 geocode/mapと監査LOW残件を処理する。
- [ ] reasoning表示、宣言型network permission、geolocationを将来sliceとして扱う。

## 6. 完了・棚卸し条件

- 現sliceの完了は、対象実装だけでなく対応test、必要な専用Simulator E2E、`make verify`、docs/log反映を要する。
- SessionStart hookはheadだけを注入し、マーカー以降の行数と更新block数を測る。
- 閾値超過時は完了済み計画を日付付きarchiveへ移し、最新docからリンクする。archiveは削除しない。
- 詳細な試験票・設計・時系列記録は各専用docを正とし、この文書へ結果全文を重複させない。

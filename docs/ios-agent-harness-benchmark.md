# iOS エージェントハーネス正式評価

> **状態:** Phase 0完了・Codex AのH-01/K-01完走・Dのlocal probeとmain O-01完走
> **正典の範囲:** Claude Code / Codex から `swift-mcp-app` を build・操作・E2E 検証する
> plugin / skill / MCP / CLI の比較と採否。製品ロードマップ自体は `docs/next-directions.md` を正とする。
> **更新方法:** 結果を上書きせず、各試験のチェックボックスと結果表を更新する。生の経緯は
> `docs/log.md` に追記する。

## 1. 目的と判断基準

次の4条件を同時に満たす構成を選ぶ。

1. Claude Code CLI / Codex CLI のどちらからも使える。
2. build・Simulator操作・OAuth・WKWebView内のMCP Apps操作を人手なしで完走できる。
3. 常時注入するskill本文とMCP tool schemaを小さく保ち、詳細はproject skillへ遅延ロードする。
4. 失敗時にスクリーンショットだけで推測せず、semantic snapshot・unified log・MCP疎通で裏取りできる。

GUI mirrorやSimulator browserは、それ自体を目的にしない。semantic操作やSwiftUI Previewに必要な場合だけ
有効化する。公式pluginの採用・不採用を先に決めず、同一タスクの成否と計測値で判断する。

## 2. 比較対象

| ID | 構成 | 目的 |
| --- | --- | --- |
| A | 現行 `ios-simulator`(simctl + idb) + project `ios-e2e-verify` | 現行baseline |
| B | OpenAI公式 `build-ios-apps` 0.1.2を無変更 | stock pluginとしての実用性 |
| C | Bのskill + XcodeBuildMCP 2.6.2を`bunx`固定 | plugin設計と依存versionずれを分離する診断用 |
| D | XcodeBuildMCP 2.6.2最小workflow + idb fallback + project `ios-e2e-verify` | 本採用候補(hybrid) |

Bは公式設定の`npx ...@latest`を含めて無変更で一度測る。Bがversionずれで失敗した場合だけCを測り、
「公式skillの問題」と「浮動依存の問題」を分ける。DのJS依存は評価中`bunx xcodebuildmcp@2.6.2`、
採用後はまず同じ固定指定を使う。Nix packagingは評価対象外とし、再現性が不足した場合にだけ
dotfilesの`package.json + bun.lock`、さらに必要ならNix derivationへ進む。

## 3. 公平な実行方法

### 3.1 コンテキスト分離

- 1構成×1試験につき新しいsubagentを`fork_turns=none`で起動する。
- subagentへ渡すのは、対象plugin/skillの場所、試験prompt、専用Simulator UDID、固定commitだけ。
- 事前調査の結論、他構成の結果、期待する勝者を渡さない。
- 各構成は隔離したCodex home / Claude configで起動し、比較対象外のiOS skillやMCPを見せない。
- 同一試験のsubagent同士を会話させない。raw tool traceと成果物だけをmainへ返す。
- 同じSimulatorを並列操作しない。構成ごとに同じbaseから作った専用Simulatorを割り当てる。

main sessionは実装担当にならず評価者になる。subagentの「成功した」という文章だけを採用せず、
画面、semantic tree、unified log、保存状態、MCP tool結果を独立して確認する。必須試験はmainが
採用候補で再実行する。

### 3.2 固定する条件

- repo commit SHA、Xcode/XcodeBuildMCP/idb/OS runtimeのversionを記録する。
- `MCPHost.xcodeproj`は同じ手順で生成し、DerivedDataの初期状態を試験間で揃える。
- 専用Simulatorだけをreset対象にする。日常利用中のSimulatorをeraseしない。
- caldav / tdr-conciergeのdeploy commitと稼働状態を開始前に記録する。
- 実credentialを使用しない。OAuth試験は公開された使い捨てfixture `changeme`だけを使う。
- API keyが必要な試験は同じenv注入経路を使い、値をprompt・trace・成果物へ出さない。

## 4. 試験票

### H-01: ハーネス発見と初動

**prompt:** 「このrepoをiPhone 17 Simulatorでbuildして起動し、現在画面を証拠付きで報告して」

合格条件:

- 対象scheme・project・booted Simulatorを誤配送せず決定する。
- build → install → launchを完走する。
- 表示画面をsemantic snapshotまたはアクセシビリティtreeとスクリーンショットの両方で確認する。
- repo固有skillを必要な時だけ読み、無関係なiOS skillを常時ロードしない。

### K-01: ネイティブ入力・訂正

**prompt:** 「サーバー追加画面で、表示名を入力し、URLを一度誤入力してから削除・修正して。保存はしない」

合格条件:

- fieldをラベルまたはsemantic refで選択し、固定座標を第一選択にしない。
- ASCII入力、backspace、全選択または置換を人手なしで行う。
- focus/blurに応じたURL validation表示を確認する。
- 日本語入力は直接入力またはclipboard経路で実現し、採った経路を記録する。

### O-01: OAuthフルフロー

**prompt:**

> MCPHostからcaldavへ接続してください。検証環境専用の使い捨てパスワードは`changeme`です。
> OAuth完了、接続済み、caldav tool 1回成功、アプリ再起動後の無言再接続まで証拠付きで確認してください。

合格条件:

- system OAuth画面またはWeb画面のpassword fieldを発見して`changeme`を入力できる。
- callbackでMCPHostへ戻り、serverがreadyになる。
- toolを1回呼び、結果を確認する。
- terminate / relaunch後はブラウザを出さずKeychain tokenで自動接続する。
- 実credential一般を入力してよい、という規則へ拡大解釈しない。

### W-01: MCP Apps / WKWebView

**prompt:** 「caldavのtodosまたはagendaカードを表示し、カード内操作、fullscreen、復帰を検証して」

合格条件:

- 通常チャット経由で実カードを表示する。スパイクだけで代用しない。
- WKWebView内の操作対象を発見し、最低1回のtools/call往復を完走する。
- fullscreen前後で同一WebViewのJS状態が維持される。
- semantic treeでWeb contentが不足する場合はidb・座標・ログへfallbackし、その判断根拠を残す。

### L-01: ログと障害復旧

**prompt:** 「意図的に不正なMCP URLを設定し、失敗理由を画面とログで特定して元へ戻して」

合格条件:

- UI文言だけで原因を断定しない。
- subsystem `dev.gigun.mcphost`のunified logを取得する。
- 修正後に接続または入力validationが回復したことを再確認する。

### M-01: 複数Simulator誤配送防止

**prompt:** 「指定されたUDIDだけでMCPHostをbuild/runし、別のbooted Simulatorを変更しないで」

合格条件:

- `booted`という曖昧指定をinstall/launch先に使わない。
- build、install、launch、snapshotの全工程で同一UDIDを使う。

### X-01: Apple Xcode MCP(optional gate)

**prompt:** 「Xcodeの現在projectに対して利用可能なIDE専用toolを列挙し、PreviewまたはIssue Navigatorを1回使って」

合格条件:

- `xcrun mcpbridge`またはXcodeBuildMCPの`xcode-ide` gatewayで接続する。
- timeout時はPID/session/trust/Xcode windowを切り分け、無限再試行しない。
- この試験の失敗だけでSimulator E2E構成を不採用にしない。

## 5. 計測と採点

各subagentについて次を記録する。

| 指標 | 記録方法 |
| --- | --- |
| 成否 | 上記合格条件ごとのpass/fail。部分成功を成功扱いしない |
| 人手介入 | 回数と理由。`changeme`入力をユーザーへ頼んだ場合は1回 |
| 所要時間 | prompt投入から最終証拠取得までのwall time |
| tool call | 種類、総数、失敗、retry、同じsnapshotの再取得回数 |
| MCP context | `tools/list`のtool数、serialized bytes、同じ方法でのtoken概算 |
| skill context | 常時metadata、実際にロードしたSKILL.mdのbytes/token概算 |
| response量 | 大きなsemantic snapshot・ログのbytesと、絞り込みの有無 |
| 証拠品質 | screenshot / semantic tree / log / MCP結果 / 再起動後状態の有無 |
| 誤操作 | 隠れたNavigationStack、別Simulator、別serverを操作した回数 |

採用必須gate:

- O-01、W-01、M-01を2回連続で完走する。
- test credentialを除き人手で秘密を入力しない。
- 別Simulator・別serverへの誤配送が0件。
- semantic snapshotだけを成功根拠にせず、画面またはログと突き合わせる。
- Dの常時MCP tool数は公式stockより少なくする。稀な操作はCLIへ逃がす。
- Claude Code CLI / Codex CLIの両方でH-01とO-01を最低1回通す。

## 6. main sessionの実行順と進捗

### Phase 0: 環境と試験fixture

- [x] 評価対象commitを`9d2c168823256933d2a32e56f5098ab23435b751`へ固定し、開始時cleanを記録する。
- [x] A/B/C/D用の隔離configと専用Simulatorを用意する。
- [x] caldavの`changeme`が検証専用fixtureであることと接続先環境を明記する。
- [x] A/DのMCP `tools/list`、skill metadata/body量を採取する。
  > **2026-07-23 更新:** Dは36 tools / 225,990 serialized bytes、project skill metadataは1,427 bytes。
  > Bの無変更実行はunpinnedな`npx ...@latest`を含むため実行せず、A/Dで具体的な差が残った場合だけ
  > B/Cを診断する。mutableなthird-party code実行を「公平性」のためだけに先行させない。
- [x] raw trace・スクリーンショット・ログの保存先を
  `/private/tmp/swift-mcp-app-ios-harness-9d2c168`配下に固定する。

### Phase 1: Codexでのblind比較

- [ ] H-01をA/Dで各1回blind実行する。
  > **2026-07-23 更新:** Aは合格。D担当subagentにはXcodeBuildMCP toolが露出せずCLI+idb fallbackで
  > 機能上は合格したが、Aとの差を測れていないためDのblind結果には数えない。
- [ ] K-01をA/Dで各1回blind実行する。
  > **2026-07-23 更新:** Aは合格。Dはmain sessionからlocal MCPへ直結したcapability probeでは合格したが、
  > 外部`codex exec`によるblind実行はrepo文脈の外部送信を伴うため、ユーザーの明示承認待ち。
- [ ] O-01をA/B/Dで各2回実行する。
  > **2026-07-23 更新:** 正式blind比較とは別にmainがDを独立再実行。署名済みappで`changeme`入力、
  > callback、caldav 23 tools、`get-current-time`成功、terminate/relaunch後のbrowserなし無言接続まで
  > 完走した。初回に発見した無署名runのKeychain `-34018`は`make run`だけad-hoc署名へ戻して解消。
- [ ] W-01をA/B/Dで各2回実行する。
  > **2026-07-23 更新:** 正式比較とは別にmainのD独立再実行は合格。実todosカードの
  > `refresh-todos`/`list-calendars`往復、fullscreen往復、collection menuのJS状態保持、
  > 作成時の安定focusをscreenshotとunified logで照合した。semantic helperが背後の検索欄を
  > 誤選択した2回は誤操作として記録し、composer固有patternへ修正した。
- [ ] L-01とM-01をA/B/Dで各1回実行する。
- [ ] Bの失敗が依存version由来の場合だけCで該当試験を再実行する。
- [ ] mainがraw traceを採点し、採用候補のO-01/W-01を独立再実行する。

### Phase 2: Claude CodeとのCLI parity

- [ ] Claude Codeのrate limit解消後、隔離configでH-01を再実行する。
- [ ] 同じ構成でO-01を再実行する。
- [ ] Claude固有tool名やCodex Desktop/Browser依存が残っていないか確認する。

### Phase 3: 採用・実装

- [ ] 結果表を本docへ追記し、A/B/C/Dの採否と根拠を確定する。
- [ ] generic knowledgeをuser plugin、MCPHost固有知識を`ios-e2e-verify`へ反映する。
- [x] ~~real secret禁止とdisposable test credential許可をskillに明記する。~~ ✅ 2026-07-23
- [ ] 採用するMCP workflowを最小化し、Xcode IDE gatewayはtimeout解消後にoptionalで有効化する。
- [ ] dotfilesはまずBun/NodeとMCP登録を管理し、XcodeBuildMCPは固定版`bunx`で運用する。
- [ ] Claude Code / Codex双方のvalidator、`make check`、必須E2Eを通す。
- [ ] `docs/next-directions.md`と`docs/log.md`へ最終判断を反映する。

## 7. 2026-07-23 予備調査(正式評価には数えない)

- `bunx xcodebuildmcp@2.6.2 --version`は成功。実行runtimeはpackageのshebangどおりNodeだった。
- doctorでXcode 26.4、AXe 1.7.1、UI automation、`lldb-dap`の利用可能を確認した。
- MCP起動時の登録tool数はdefault simulator=24、simulator+ui-automation+xcode-ide=38、
  ui-automation+xcode-ide=20だった。
- OpenAI公式0.1.2の`logging` workflowは2.6.2でunknownとして無視された。公式debugger skillにも
  現行名と異なる`describe_ui`、`start_sim_log_cap`等があり、stockのversionずれを確認した。
- 起動中MCPHostでXcodeBuildMCPのsemantic snapshotは成功したが、表示中フォームだけでなく背後の
  NavigationStackを含む307要素を返した。同画面のidbは表示中7要素だった。
- semantic refによる「キャンセル」tap自体は成功したが、post-action snapshotは2.5秒でsettleせず、
  明示的な再snapshotが必要だった。
- XcodeBuildMCP経由のXcode IDE tool一覧はPID指定の有無にかかわらずtimeoutした。原因未確定。
- build/run、文字訂正、日本語、OAuth、WKWebView、subagent分離比較は未実施。以上を正式評価の
  成功根拠に使わない。

## 8. 2026-07-23 正式評価結果（固定commit `9d2c168`）

| 試験 | 構成 | 判定 | wall time | tool calls / retry | 証拠と判断 |
| --- | --- | --- | --- | --- | --- |
| H-01 | A | **Pass** | 約3分30秒 | 15 / 1 | 明示UDIDでbuild・install・launch。screenshotと10要素のflat accessibilityをmainも再確認 |
| H-01 | D | **No score** | 約2分44秒 | 16 / 1 | 機能上は完走したがXcodeBuildMCPがsubagentへ露出せず、CLI+idbへ全面fallbackしたためD比較になっていない |
| K-01 | A | **Pass** | 約6分30秒 | 39 / 3 | 日本語clipboard、誤URL、backspace、Select All/Paste、blur、Cancel後に未保存を確認 |
| K-01 | D | **Local pass / blind pending** | 非blind | 未集計 | XcodeBuildMCP 2.6.2へlocal JSON-RPC直結しsemantic refsを検証。最終blind scoreには含めない |
| W-01 | D | **Main independent pass / blind pending** | 非blind | 未集計 | 実Appの操作往復・同一WebView状態保持・fullscreen作成focusを画面/logで確認。正式各2回には含めない |

### H-01 Aの証拠

- screenshot: `/private/tmp/swift-mcp-app-ios-harness-9d2c168/artifacts/H-01-A.png`
- accessibility: `/private/tmp/swift-mcp-app-ios-harness-9d2c168/artifacts/H-01-A-accessibility.json`
- raw command record: `/private/tmp/swift-mcp-app-ios-harness-9d2c168/raw/H-01-A-command-record.md`
- build 26.801秒、install 4.189秒、launch PID 2143。別Simulator操作0、人手介入0。

### K-01 Aの証拠と発見

- 誤URL / backspace / 最終blur / cancel後の4画面を`artifacts/K-01-A-*`へ保存した。
- 表示名`検証サーバー`はclipboard + semantic `Paste`で入力した。

### W-01 D main独立再実行の証拠と発見

- inline、collection menu、fullscreen、inline復帰、作成focusの画面を`artifacts/w01-*`と
  `artifacts/focus-fix-fullscreen-keyboard-stable.png`へ保存した。
- inline→fullscreen→inlineでcollection menuのopen状態が維持され、同一WKWebViewのJS状態保持を確認した。
- semantic snapshotは非表示drawerの検索欄も返すため、曖昧な`text-field`指定で2回誤入力した。
  composerはplaceholderを含む固有pattern、カード内部は画面確認後の座標fallbackが必要。
- `idb ui text`は現在のkeyboard layoutで`:`を`;`へ変換した。URLは直接typeに固執せず、
  clipboard置換をfallbackにする必要がある。
- 最後にsemantic `キャンセル`で閉じ、一覧が既存`caldav` 1件のままであることを確認した。

### K-01 D local capability probeの証拠と発見

- XcodeBuildMCP `snapshot_ui`は表示名・URLを安定してtext-field refとして返し、`type_text`の
  `replaceExisting`と`key_sequence([42])`による全置換・backspaceは成功した。
- AXe `type_text`は日本語を`US keyboard characters only`で拒否し、ASCIIの`:`も`;`へ変換した。
- clipboardは必要。長押し後の`Paste`はsnapshotの**text**には出るがtap可能targetには出ない。
  `idb ui describe-all`では`Paste`のframeを取得できるため、そのsemantic frame中心だけを座標fallbackにした。
- 誤入力blur時に`https:// で始まる URLを入力してください`を画面とsnapshotで確認。その後
  `https://example.com/mcpx`を貼り、XcodeBuildMCP backspaceで末尾を削除して
  `https://example.com/mcp`へ修正、表示名`テストサーバー`を保持したままblurできた。
- `artifacts/K-01-D-paste-menu.png`と`artifacts/K-01-D-final-blurred.png`、各段階のraw JSONを保存。
  semantic refの内側だけで日本語pasteを完結できないため、Dを採る場合もidb fallbackは削除しない。

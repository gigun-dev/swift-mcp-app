# iOS エージェントハーネス正式評価

> **状態:** AのH-01/K-01、Dのlocal probe、main独立のO-01/W-01、AでのL-01/M-01まで完走した。
> OpenAI公式stock BはCLI既定30秒でtool schema取得timeoutしたが、120秒timeout診断armでH-01 Pass、
> Codex Desktop taskで追加設定なしに起動してK-01 Pass。探索E2Eへ条件付き採用する。
> 固定版D + Aのidb fallbackを探索E2Eに採用し、Apple Xcode MCPと将来のXCUIAutomationを
> 直交するevidence / regression層として積む。判断の要約と公式出典は
> [`codex-plugin-and-ios-agent-audit.md`](codex-plugin-and-ios-agent-audit.md)を正とする。
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
| B | OpenAI公式 `build-ios-apps` 0.1.2 / revision `d6169bef`を無変更 | **条件付き採用**: DesktopでH-01/K-01 Pass。CLI既定30秒timeoutと`@latest` driftは残る |
| C | Bのskill + XcodeBuildMCP 2.6.2を`bunx`固定 | Bが失敗した場合のversion / tool drift診断arm |
| D | XcodeBuildMCP 2.6.2最小workflow + idb fallback + project `ios-e2e-verify` | **採用**: semantic操作が必要な探索E2E |

当初どおりBを無変更で測り、失敗時だけCでversionずれを診断する。source inspectionで確認した
`npx ...@latest`とtool名・workflow driftはリスクとして記録するが、それだけでBを不採用にしない。
Dは比較可能性のため`bunx xcodebuildmcp@2.6.2`の固定指定を維持する。

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
  > **2026-07-23 再更新:** B 0.1.2 / revision `d6169bef`をinstallし、新規Codex sessionで
  > `ios-debugger-agent`をロードした。初回stock H-01はData volume 100%・空き2.4 GiBかつ
  > `No space left on device`の状態でMCP serverが起動せずNo score。環境復旧後に再実行する。
- [x] raw trace・スクリーンショット・ログの保存先を
  `/private/tmp/swift-mcp-app-ios-harness-9d2c168`配下に固定する。

### Phase 1: Codexでのblind比較

> **2026-07-23 再更新:** ユーザー指示によりstock Bの実測をactive taskへ戻した。source inspectionだけで
> 採否を閉じず、環境復旧後のH-01/K-01で判断する。A/Dの既取得結果はbaselineとして保持する。

- [ ] H-01をA/Dで各1回blind実行する。
  > **2026-07-23 更新:** Aは合格。D担当subagentにはXcodeBuildMCP toolが露出せずCLI+idb fallbackで
  > 機能上は合格したが、Aとの差を測れていないためDのblind結果には数えない。
- [x] ~~H-01をstock Bで再実行する。~~ ✅
  > **2026-07-23 初回:** global install / skill load / MCP登録までは成功。`npx`初回取得が60秒無出力、
  > exit 130となりrequired MCP toolsが公開されなかった。容量不足が同時発生したためNo score。
  > 記録: `/private/tmp/swift-mcp-app-ios-harness-9d2c168/official-build-ios-apps-d6169bef/H-01-B/`。
  > **2026-07-23 再試験:** 空き14 GiBで`@latest` 2.6.2を事前取得し、fresh sessionでskillを全文ロードしたが、
  > `tools/list`が30秒timeoutして必須tool 0件のまま停止した。direct stdio probeではserverは約0.2秒で起動し、
  > 44 tools / 約63,469 tokensのschemaを返した。容量・networkではなくstockのversion/schema driftによるFail。
  > 記録: `/private/tmp/swift-mcp-app-ios-harness-9d2c168/official-build-ios-apps-d6169bef/H-01-B-rerun-20260723/`。
  > **2026-07-23 訂正:** schema量を単独原因、stockを互換性不合格と断定した判断を撤回する。
  > 同じcommand / args / envへ`startup_timeout_sec=120`だけを追加すると44 toolsが公開され、
  > `session_show_defaults` / `session_set_defaults` / `build_run_sim` / `snapshot_ui` / `screenshot`を完走した。
  > Harness Bへbuild / install / launch成功（56.8秒、PID 90578）、semantic 49要素 / 7 targets、JPEG取得成功。
  > 許可prompt・fallbackは0。確定原因は既定30秒のstartup deadline不足までとする。
- [ ] K-01をA/Dで各1回blind実行する。
  > **2026-07-23 更新:** Aは合格。Dはmain sessionからlocal MCPへ直結したcapability probeでは合格したが、
  > 外部`codex exec`によるblind実行はrepo文脈の外部送信を伴うため、ユーザーの明示承認待ち。
- [x] ~~K-01をstock BのCodex Desktop taskで実行する。~~ ✅
  > **2026-07-23 更新:** Harness Bへbuild / install / launch（12.5秒、PID 32776）後、semantic refだけで
  > サーバー追加画面へ遷移。日本語clipboard、誤URL、backspace、Select All / Paste、focus / blur validation、
  > キャンセル後の未保存を確認した。`replaceExisting:true`はIME下で文字化けしても成功応答だったため、
  > snapshotの実値を見てclipboard置換へ回復した。macOS / Xcode promptは0、clipboardだけCodex sandbox許可あり。
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
  > **2026-07-23 main独立再実行:** L-01はAでlocal HTTP MCPの501をserver詳細とunified logで照合し、
  > probe削除・port閉鎖・失敗状態消滅まで確認。M-01はA/D同時bootedでAの明示UDIDだけへ
  > build/install/launch/snapshotし、非対象Dのcontainer pathとbinary SHA-256が前後一致した。
  > 正式blind A/B/D比較には含めない。
- [ ] Bの失敗が依存version由来の場合だけCで該当試験を再実行する。
- [ ] mainがraw traceを採点し、採用候補のO-01/W-01を独立再実行する。

### Phase 2: Claude CodeとのCLI parity

- [ ] Claude Codeのrate limit解消後、隔離configでH-01を再実行する。
- [ ] 同じ構成でO-01を再実行する。
- [ ] Claude固有tool名やCodex Desktop/Browser依存が残っていないか確認する。

### Phase 3: 採用・実装

- [x] ~~結果表を本docへ追記し、A/B/C/Dの採否と根拠を確定する。~~ ✅ 2026-07-23
- [ ] generic knowledgeをuser plugin、MCPHost固有知識を`ios-e2e-verify`へ反映する。
  > **2026-07-23 更新:** project知識は先行反映済み。残りはgeneric `ios-simulator`の明示UDID、
  > bounded poll、実行時scaleと、`ios-device-build`のprovider固定path解消。`gigun-dev/claude-code`へ
  > scopeを移してFableが実装する。
- [x] ~~real secret禁止とdisposable test credential許可をskillに明記する。~~ ✅ 2026-07-23
- [x] ~~採用するMCP workflowを最小化し、Xcode IDE gatewayはtimeout解消後にoptionalで有効化する。~~ ✅
  > **2026-07-23 更新:** Apple公式`xcrun mcpbridge`直結は20 toolsで実働しX-01 Pass。
  > XcodeBuildMCP経由の`xcode-ide` gateway timeoutとは別経路なので、gatewayを重ねずApple MCPを使う。
- [ ] dotfilesはまずBun/NodeとMCP登録を管理し、XcodeBuildMCPは固定版`bunx`で運用する。
- [ ] Claude Code / Codex双方のvalidator、`make check`、必須E2Eを通す。
- [x] ~~`docs/next-directions.md`と`docs/log.md`へ最終判断を反映する。~~ ✅ 2026-07-23

### X-01: Apple Xcode MCP（A〜Dと直交するIDE層）

- [x] ~~`XcodeListWindows`で`MCPHost.xcodeproj` / `windowtab1`を取得する。~~ ✅ 2026-07-23
- [x] ~~`XcodeListNavigatorIssues`でIssue Navigatorを取得する。~~ ✅ 2026-07-23
- [x] ~~Apple MCPをSimulator UI backendの代替とせず、docs/build/test/issues/Preview専用に位置づける。~~ ✅

Issue Navigatorはworking treeにSwift 6 captured-`self` warning 2件と不要`await` 1件を検出した。
`make verify`成功とcompiler warning 0は別gateとして扱い、delivery前のFable queueへ送った。

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
| H-01 | B stock + 120秒timeout診断 | **Pass** | build/run 56.8秒 | 5 / 0 | Harness Bへbuild・install・launch、49要素のsemantic snapshot、JPEGを取得。許可prompt / fallback 0。既定30秒では開始不能 |
| H-01 | D | **No score** | 約2分44秒 | 16 / 1 | 機能上は完走したがXcodeBuildMCPがsubagentへ露出せず、CLI+idbへ全面fallbackしたためD比較になっていない |
| K-01 | A | **Pass** | 約6分30秒 | 39 / 3 | 日本語clipboard、誤URL、backspace、Select All/Paste、blur、Cancel後に未保存を確認 |
| K-01 | B stock / Codex Desktop | **Pass** | 約5分 | 47 / 2 | semantic ref、clipboard日本語、ASCII誤入力、backspace、Select All/Paste、validation、未保存を確認。IME文字化けをsnapshotで検出・回復 |
| K-01 | D | **Local pass / blind pending** | 非blind | 未集計 | XcodeBuildMCP 2.6.2へlocal JSON-RPC直結しsemantic refsを検証。最終blind scoreには含めない |
| W-01 | D | **Main independent pass / blind pending** | 非blind | 未集計 | 実Appの操作往復・同一WebView状態保持・fullscreen作成focusを画面/logで確認。正式各2回には含めない |
| L-01 | A | **Main independent pass / blind pending** | 非blind | 未集計 | UI詳細の501とunified logを照合し、probe削除・一時server停止後の復旧まで確認 |
| M-01 | A（Dを非対象） | **Main independent pass / blind pending** | 非blind | 未集計 | 全工程をA UDIDへ固定し、Dのapp container path/binary SHA-256不変を確認 |

### H-01 Aの証拠

- screenshot: `/private/tmp/swift-mcp-app-ios-harness-9d2c168/artifacts/H-01-A.png`
- accessibility: `/private/tmp/swift-mcp-app-ios-harness-9d2c168/artifacts/H-01-A-accessibility.json`
- raw command record: `/private/tmp/swift-mcp-app-ios-harness-9d2c168/raw/H-01-A-command-record.md`
- build 26.801秒、install 4.189秒、launch PID 2143。別Simulator操作0、人手介入0。

### H-01 B stock初回・再試験の証拠

- plugin: OpenAI `build-ios-apps` 0.1.2 / cache revision `d6169bef`（installed, enabled）。
- fresh `codex exec` sessionは`ios-debugger-agent`全文を読み、plugin `.mcp.json`も特定した。
- `codex mcp list`では`xcodebuildmcp`がenabledだが、sessionのactive toolsへは公開されなかった。
- stock entry `npx -y xcodebuildmcp@latest`は60秒無出力後exit 130。npm cacheにpackage実体なし。
- 同sessionに`No space left on device`、Data volume 100%・空き2.4 GiBを確認したためNo score。
- plugin外fallback、build、Simulator操作、repo変更は0。failure reportのみ上記artifact directoryへ保存した。
- 再試験前はData volume空き14 GiB。`npx -y xcodebuildmcp@latest --version`は`2.6.2`を返し、package取得も成功した。
- fresh `codex exec`は約108秒後、`timed out awaiting tools/list after 30s`で終了。必須MCP callは0。
- 同じstock entryへのdirect stdio probeは約0.2秒でinitializeし、2.6.2が44 toolsを登録した。
  plugin指定の`logging`はunknownとして無視され、`tools/list`応答は約63,469 tokensだった。
- 再試験記録は`official-build-ios-apps-d6169bef/H-01-B-rerun-20260723/`。fallback、build、Simulator操作は0。
- 上記の不合格断定は撤回した。`startup_timeout_sec=120`診断armでは44 toolsが公開され、H-01はPass。
- 使用toolは`session_show_defaults`、`session_set_defaults`、`build_run_sim`、`snapshot_ui`、`screenshot`の5件。
- Harness Bへのbuild / install / launchは56.8秒、PID 90578。semantic snapshotは49要素 / 7 targets。
- screenshot: `official-build-ios-apps-d6169bef/H-01-B-timeout120/H-01-B.jpg`（368x800 JPEG）。
- macOS / Xcode許可prompt、別backend fallback、repo変更はいずれも0。

### K-01 Aの証拠と発見

- 誤URL / backspace / 最終blur / cancel後の4画面を`artifacts/K-01-A-*`へ保存した。
- 表示名`検証サーバー`はclipboard + semantic `Paste`で入力した。

### K-01 B Desktopの証拠と発見

- 記録: `official-build-ios-apps-d6169bef/K-01-B-desktop/`。誤URL focus / blur、backspace、
  IME文字化け、訂正後blur、キャンセル後一覧の6画面と`final-report.md`を保存した。
- Harness Bへ現行dirtyをbuild / install / launchし、buildは12.5秒、PID 32776。caller指定の固定座標は0。
- `type_text`の日本語は`US keyboard characters only`で明示的に失敗したため、`simctl pbcopy`後に
  semantic fieldをlong-pressし、snapshot内の`Paste` text refへ`touch`して`検証サーバー`を入力した。
- `htp://bad`はfocus中にvalidation非表示、表示名fieldへblur後に
  `https://、または開発用の localhost URL を入力してください。`が出た。keycode 42で`htp://ba`へ削除した。
- `replaceExisting:true`は成功応答でもIMEにより`hっtps：・・えぁmpぇ。cおm・mcp`へ化けた。
  long-press → semantic `Select All` → `Paste`で`https://example.com/mcp`へ直し、blur後の警告消滅を確認した。
- 追加画面と設定画面をキャンセルし、既存`caldav` 1件だけで未保存を確認した。macOS / Xcode許可promptは0。
  clipboard用`xcrun simctl pbcopy`のみCodex sandbox approvalを使い、UI操作の外部backend fallbackは0。

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

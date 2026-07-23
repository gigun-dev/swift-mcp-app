# iOS Simulator 検証の標準運用と Codex 非依存方針

> **結論:** このリポジトリの必須検証経路は Codex や OpenAI の
> `build-ios-apps` plugin に依存させない。plugin は Codex Desktop で探索検証を始めやすくする
> optional adapter として扱う。再現可能な正規経路は、repo の `make` target、
> source-controlled XCUIAutomation、固定版 XcodeBuildMCP の CLI / MCP、`xcrun simctl`、
> project skill `ios-e2e-verify`、実機検証で構成する。
>
> plugin の比較実測は
> [`ios-agent-harness-benchmark.md`](ios-agent-harness-benchmark.md)、Codex plugin の構造と公式出典は
> [`codex-plugin-and-ios-agent-audit.md`](codex-plugin-and-ios-agent-audit.md)を正とする。

## 1. 現在の構成と採否

| 構成 | 現在の状態 | 標準での役割 |
| --- | --- | --- |
| OpenAI `build-ios-apps` 0.1.2 | install / enable済み。Codex DesktopでH-01/K-01 Pass | **任意。** Codex Desktopでの一時的な探索、公式skillとの差分確認 |
| XcodeBuildMCP 2.6.2 | stock pluginの`@latest`が現在この版へ解決。固定版armでも実測済み | **採用。** client非依存の構造化build / run / semantic操作。版を固定する |
| `ios-skills@gigun` 1.0.0 | install / enable済み。skill-onlyでMCPは含まない | **要修繕のfallback。** `simctl + idb`の薄い汎用操作 |
| Apple Xcode MCP | 接続済み、X-01 Pass | IDEのbuild / test / Issue Navigator / Preview。runtime UI操作の代替ではない |
| project `ios-e2e-verify` | repo管理、Claude/Codexからsymlink共有 | OAuth、credential、WKWebView、MCP Apps、unified logの正典 |
| XCUIAutomation | 追加予定 | 合意済みnative flowの恒久回帰 |

2026-07-23の再確認では、XcodeBuildMCPの`session_show_defaults`と`list_sims`は成功した。
同時に4台のSimulatorがBootedだったため、名前や`booted`という曖昧な宛先ではなく、全工程を同一UDIDへ
固定する必要がある。

一方、現行`ios-skills`の手順にある引数なし`idb connect`は、導入済みCLIの構文と一致しない。
`idb list-targets`も古いcompanion登録を除去した後に失敗し、sandbox外での再試行は完了せず停止した。
`idb` 1.1.7と`idb_companion` 1.1.8の版差、古いsocket、現行Xcodeとの互換性を整理するまで、
この経路を「すぐ使える標準fallback」とは扱わない。古いsocketやSimulatorの削除は診断だけを理由に行わない。

## 2. `build-ios-apps`は必須か

**必須ではない。** pluginが提供する価値は、主に次の2つをCodexへまとめて導入することにある。

1. SwiftUI、debug、performance、Simulator操作などのskill本文
2. 外部OSSであるXcodeBuildMCPを起動する`.mcp.json`

実際のbuild、install、launch、accessibility snapshot、tap、入力、log、debugは
XcodeBuildMCP、Xcode、Simulator側で実行される。XcodeBuildMCPはMCP以外にCLIも公開し、
Claude Code、Codex CLI、Cursor、VS Codeなど複数clientをサポートする。そのためpluginを外しても、
固定版XcodeBuildMCPを直接登録するかCLIで呼べば、iOS検証能力は維持できる。

### Codexから外へ移せるもの

| 能力 | Codex非依存の代替 |
| --- | --- |
| project / scheme / Simulator発見 | repo設定、`xcodebuild -list`、`xcrun simctl list`、XcodeBuildMCP CLI |
| build / test / install / launch | `make`、`xcodebuild`、`xcrun simctl`、固定版XcodeBuildMCP |
| semantic snapshot / tap / type / swipe | 固定版XcodeBuildMCPのUI automation、修繕後のidb、XCUIAutomation |
| screenshot / video / runtime状態 | `simctl io`、XcodeBuildMCP CLI |
| log / debugger | `simctl spawn log`、LLDB、固定版XcodeBuildMCP |
| 安定したUI回帰 | source-controlled XCUIAutomation |
| OAuth / WKWebView / MCP Apps固有手順 | repoの`ios-e2e-verify` skillと専用fixture |
| skillの判断規則 | provider中立なMarkdown skillとしてrepo / 共通pluginで管理 |

### Codexにだけ残るもの

- Codex Marketplaceからのinstall / update / enable UI
- Codex taskへのskillとMCP toolの自動公開
- Codex Desktop内の承認表示や、結果を会話へ統合する操作体験
- Codex固有のin-app Browser連携を使うSimulator mirror

これらは**導入と操作のUX**であり、buildやSimulator E2Eの成立条件ではない。したがって
「Codexでしか検証できない製品挙動」は現時点でない。Codex固有機能を使った結果も、最終的には
screenshot、semantic state、log、test assertionなどclient外で再確認できる証拠へ落とす。

## 3. トークン効率

2026-07-23の同一環境で、stock `build-ios-apps`は未知の`logging`を含むworkflow指定から
44 toolsを公開し、`tools/list`は約63,469 tokensだった。Codex CLIの既定30秒ではschema取得が
timeoutし、120秒へ延長すると利用できた。固定版の既存D構成
`simulator,ui-automation`は36 tools / 225,990 serialized bytesで、stockより8 tools少ないだけである。
これは改善ではあるが、十分に小さいとは判定しない。

[XcodeBuildMCPの公式workflow仕様](https://www.xcodebuildmcp.com/docs/workflows)では、MCPへ広告した
全toolがcontextを消費する一方、CLIは`--help`で段階的に発見でき、事前のtool schema負担がない。
[MCP設定](https://www.xcodebuildmcp.com/docs/mcp-mode)は明示toolだけのcustom workflowも許す。
したがって標準は次の三段階にする。

1. **常時:** `make check/app/verify`、XCUIAutomation、`simctl`、XcodeBuildMCP CLI。
   buildだけのタスクでUI automation MCPをロードしない。
2. **探索時だけ:** session defaults、build/run、snapshot、wait、tap、type、swipe、screenshotに絞った
   固定版XcodeBuildMCP custom workflowを起動する。
3. **障害時だけ:** logging、debugging、profiling、memgraphを別sessionまたはCLIで追加する。

次の改善ではcustom workflowの実tool集合を固定し、stock 44 tools、既存D 36 tools、新構成について
同じtokenizerで`tools/list` token数を再計測する。**tool数だけをtoken削減の証拠にしない。**

## 4. Simulator操作の標準手順

### 開始前

1. build / testだけで目的を満たすならSimulatorを操作しない。
2. 専用Simulatorを使い、UDIDを記録する。日常利用中の端末をeraseしない。
3. XcodeBuildMCPでは最初に`session_show_defaults`を実行する。
4. project / workspace、scheme、configuration、Simulator UDID、bundle IDが正しければ
   `build_run_sim`へ進む。違う場合だけdefaultsを設定する。
5. 複数端末がBootedでも、名前、先頭の端末、`booted`を配送先に使わない。

repo標準ではfast gateを`make verify`、署名とKeychainを含むSimulator配送を
`make run SIMULATOR_UDID=<UDID>`で行う。agentの対話的な探索では固定版XcodeBuildMCPを使えるが、
同じUDIDをbuild、install、launch、操作の全工程で維持する。

### 操作と待機

1. 操作直前にsemantic snapshotを取得する。
2. accessibility label / identifier / semantic refを優先する。
3. 画面遷移、sheet開閉、再launch後はrefを使い回さずsnapshotを更新する。
4. 固定sleepではなく、上限付きwaitと状態の再取得を使う。
5. semantic操作が使えない場合だけ、修繕済みidbのAX frame、最後に座標へ降りる。
6. 座標を使う場合はpointとscreenshot pixelを混同せず、実行時scaleから変換する。

### 入力

- XcodeBuildMCPの直接入力はUS keyboard文字を前提にする。日本語はSimulator clipboardとPasteを使う。
- `replaceExisting: true`などの成功応答だけを合格根拠にしない。K-01では成功応答後にIME文字化けした。
- 入力後はsnapshotのfield value、validation表示、保存後の永続状態を再取得する。
- clipboard用`xcrun simctl pbcopy`にCodex sandbox承認が出る場合がある。これはXcodeの信頼promptとは別物。

### 証拠

操作成功は最低でも「semantic state + screenshotまたは保存状態」で確認する。build、MCP Apps、
非同期更新、crashを扱う場合は、さらにbuild result、unified log、MCP tool結果、再起動後状態を組み合わせる。
toolが`success`を返したこと、screenshotが見た目上正しいことの片方だけではPassにしない。

## 5. project固有E2E

OAuth、credential注入、スパイクハーネス、WKWebView内のMCP Apps、JS状態、unified logは
[`../.claude/skills/ios-e2e-verify/SKILL.md`](../.claude/skills/ios-e2e-verify/SKILL.md)へ従う。

- 実credentialをprompt、trace、screenshotへ入れない。
- 資格情報不要の範囲は`MCPHOST_SPIKE`を使う。
- 環境変数は`SIMCTL_CHILD_`経路を使う。空文字注入でKeychain値を意図せず隠さない。
- OAuthは明示された使い捨てtest credentialだけを扱う。
- live caldavの副作用を持つ確認はpre-push必須回帰にせず、専用fixtureで作成・確認・削除を閉じる。

## 6. 検証済み範囲と残件

plugin採用判断に必要なH-01（発見、build、run、snapshot）とK-01（入力、訂正、validation、未保存）は
OpenAI stock pluginでPass済みであり、plugin onboardingの追加試験は不要である。

現在不足しているのはplugin能力ではなく、直近実装の製品E2Eである。

- ゆっくりdrawer dragが軸ロック後も連続追従する
- MCP App内の横gestureがdrawerへ漏れない
- 復元履歴カードが待機なしで操作できる
- `generatedAt`から60秒超のカードが表示を維持したまま背景revalidateする

これらは専用Simulatorで探索確認した後、安定したnative flowをXCUIAutomationへ昇格する。

## 7. Codex非依存化の完了条件

1. repoから固定版XcodeBuildMCP CLIを再現可能に起動できる。
2. custom workflowのtool名、版、schema token数を固定し、必要時以外MCPを起動しない。
3. generic `ios-simulator`を明示UDID、bounded wait、実行時scale、現行idb接続手順へ更新する。
4. H-01 / K-01 / O-01をCodex pluginなしの隔離環境で再実行する。
5. Claude CodeとCodexの両方から同じrepo skill / scriptを使い、provider固有tool名をadapter内へ閉じ込める。
6. 恒久回帰はXCUIAutomationと`make verify`で成立し、Codex Desktopが無くてもdeliveryできる。

完全自作を目指してXcodeBuildMCP相当を再実装することは、現時点では費用対効果が低い。
まずMITライセンスの固定版CLIを共有engineとして使い、その周囲のconfig、skill、evidence規約を
repo側で所有する。将来このengineも外す場合は、`xcodebuild + simctl + XCUIAutomation + LLDB`へ
adapter単位で置換できる構造を維持する。

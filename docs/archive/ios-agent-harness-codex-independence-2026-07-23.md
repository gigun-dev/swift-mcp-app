# Codex 非依存化とツール採否の判断記録(2026-07-23)

> **archive の位置づけ(2026-08-02 移設):** 元は
> [`docs/ios-simulator-best-practices.md`](../ios-simulator-best-practices.md) の §1〜§3・§6・§7
> だった。**日々の Simulator 検証には不要**(2026-08-01 の実走行で、agent が最初の生産的な操作へ
> 到達する前に読んだ資料は約 37,600 tokens に達し、そのうち「Codex 非依存化」の記述は
> **今回のタスクには不要だった**と報告された)。
> 一方でこれは**ツール採否の Why** —— なぜ `build-ios-apps` plugin を必須にしないのか、
> なぜ XcodeBuildMCP を版固定で使うのか —— の一次記録なので、**削除せず**ここへ退避する。
>
> **いつ読むか:** ①Codex plugin / XcodeBuildMCP / Apple Xcode MCP の**採否や版を変えたくなった時**
> ②「なぜ Codex Desktop 前提の手順になっていないのか」を疑問に思った時
> ③MCP tool schema の token 費を見直す時。
> **日常の Simulator 検証で読む必要はない**(共有スキル `ios-simulator` と
> project skill `ios-e2e-verify` で足りる)。
>
> plugin の比較実測は [`../ios-agent-harness-benchmark.md`](../ios-agent-harness-benchmark.md)、
> Codex plugin の構造と公式出典は
> [`../codex-plugin-and-ios-agent-audit.md`](../codex-plugin-and-ios-agent-audit.md)を正とする。

**結論:** このリポジトリの必須検証経路は Codex や OpenAI の `build-ios-apps` plugin に
依存させない。plugin は Codex Desktop で探索検証を始めやすくする optional adapter として扱う。
再現可能な正規経路は、repo の `make` target、source-controlled XCUIAutomation、
固定版 XcodeBuildMCP の CLI / MCP、`xcrun simctl`、project skill `ios-e2e-verify`、実機検証で構成する。

## 1. 現在の構成と採否(2026-07-23 時点)

| 構成 | 当時の状態 | 標準での役割 |
| --- | --- | --- |
| OpenAI `build-ios-apps` 0.1.2 | install / enable済み。Codex DesktopでH-01/K-01 Pass | **任意。** Codex Desktopでの一時的な探索、公式skillとの差分確認 |
| XcodeBuildMCP 2.6.2 | stock pluginの`@latest`が現在この版へ解決。固定版armでも実測済み | **採用。** client非依存の構造化build / run / semantic操作。版を固定する |
| `ios-skills@gigun` 1.0.0 | install / enable済み。skill-onlyでMCPは含まない | **要修繕のfallback。** `simctl + idb`の薄い汎用操作 |
| Apple Xcode MCP | 接続済み、X-01 Pass | IDEのbuild / test / Issue Navigator / Preview。runtime UI操作の代替ではない |
| project `ios-e2e-verify` | repo管理、Claude/Codexからsymlink共有 | OAuth、credential、WKWebView、MCP Apps、unified logの正典 |
| XCUIAutomation | 追加予定 | 合意済みnative flowの恒久回帰 |

> **2026-08-02 更新(表の3行目は失効):** `ios-skills` の `ios-simulator` は「要修繕のfallback」
> ではなくなった。2026-07-31 に UDID 明示など現行 CLI への訂正が入り(commit c60d8c6)、
> 2026-08-01 の3ラウンドの対照実験で全面改訂された。**現在は Simulator CLI 操作の唯一の原典**。
> 下の「§3 の引数なし `idb connect` が現行 CLI と一致しない」という当時の指摘は**解消済み**。

2026-07-23の再確認では、XcodeBuildMCPの`session_show_defaults`と`list_sims`は成功した。
同時に4台のSimulatorがBootedだったため、名前や`booted`という曖昧な宛先ではなく、全工程を同一UDIDへ
固定する必要がある。

一方、当時の`ios-skills`の手順にある引数なし`idb connect`は、導入済みCLIの構文と一致しない。
`idb list-targets`も古いcompanion登録を除去した後に失敗し、sandbox外での再試行は完了せず停止した。
`idb` 1.1.7と`idb_companion` 1.1.8の版差、古いsocket、現行Xcodeとの互換性を整理するまで、
この経路を「すぐ使える標準fallback」とは扱わない。古いsocketやSimulatorの削除は診断だけを理由に行わない。
(→ 上記のとおり 2026-07-31 に UDID 明示で解決済み。)

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

> **2026-08-02 補足:** この節の教訓は MCP tool schema の話だが、**skill / docs にも同じ費用がかかる**。
> 実際 2026-08-01 の実走行では、同一領域の情報源6本で約 37,600 tokens を消費していた。
> 「読ませる前に読む量を減らす」判断は tool schema と同じ基準で下す。

## 4. 検証済み範囲と残件(2026-07-23 時点のスナップショット・現在は失効)

plugin採用判断に必要なH-01（発見、build、run、snapshot）とK-01（入力、訂正、validation、未保存）は
OpenAI stock pluginでPass済みであり、plugin onboardingの追加試験は不要である。

当時「不足しているのはplugin能力ではなく直近実装の製品E2E」として挙げていた4件
(ゆっくりdrawer drag / MCP App内の横gesture / 復元履歴カード / 60秒超カードの背景revalidate)は、
**すべて `docs/next-directions.md` の「実操作チェックリスト」で ✅ 済み**。
→ **残件の正典は `docs/next-directions.md` 一箇所**。ここでは追跡しない(二重管理の解消)。

## 5. Codex非依存化の完了条件

1. repoから固定版XcodeBuildMCP CLIを再現可能に起動できる。
2. custom workflowのtool名、版、schema token数を固定し、必要時以外MCPを起動しない。
3. ~~generic `ios-simulator`を明示UDID、bounded wait、実行時scale、現行idb接続手順へ更新する。~~
   ✅ 2026-07-31〜08-01 に完了(UDID 明示・`sim-wait.py` の bounded wait・`sim-shot.sh` の
   実行時 scale 出力・`idb connect <UDID>`)。
4. H-01 / K-01 / O-01をCodex pluginなしの隔離環境で再実行する。
5. Claude CodeとCodexの両方から同じrepo skill / scriptを使い、provider固有tool名をadapter内へ閉じ込める。
6. 恒久回帰はXCUIAutomationと`make verify`で成立し、Codex Desktopが無くてもdeliveryできる。

完全自作を目指してXcodeBuildMCP相当を再実装することは、現時点では費用対効果が低い。
まずMITライセンスの固定版CLIを共有engineとして使い、その周囲のconfig、skill、evidence規約を
repo側で所有する。将来このengineも外す場合は、`xcodebuild + simctl + XCUIAutomation + LLDB`へ
adapter単位で置換できる構造を維持する。

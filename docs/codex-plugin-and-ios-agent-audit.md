# Codex公式pluginとiOS agent harness調査（2026-07-23）

> **目的:** Claude Code / Codex共有harnessのうち、Codex公式仕様と現在のCodex環境でしか
> 確認できない事項を固定する。製品ロードマップは`docs/next-directions.md`、比較のraw履歴は
> `docs/ios-agent-harness-benchmark.md`を正とする。

## 1. 結論

1. `gigun-dev/claude-code/.claude-plugin/marketplace.json`は、Codexが公式に読む
   **legacy-compatible marketplace**なので、Claude/Codex共通catalogの正典として当面維持できる。
2. 互換保証はmarketplace pathについてであり、plugin本体の公式entry pointは
   `.codex-plugin/plugin.json`である。`.claude-plugin/plugin.json`が現在動くというローカル実測と、
   公式保証を混同しない。
3. plugin cacheは管理されたinstall copyであり編集対象ではない。source repoからcacheへsymlinkを張らない。
4. iOS agent操作は単一toolへ統合しない。Apple Xcode MCP、XCUIAutomation、simctl+idb、
   固定版XcodeBuildMCP、project E2E、実機を責務別に積む。
5. OpenAI公式`build-ios-apps` 0.1.2はglobal Codex / Desktopへ導入し、H-01/K-01 Passを確認した。
   Codex Desktopの探索E2Eへ条件付き採用するが、`@latest`とskill/tool名driftのため恒久回帰には使わない。

## 2. Codex pluginの公式境界

公式仕様: [Plugins](https://developers.openai.com/codex/plugins)、
[Build plugins](https://developers.openai.com/codex/plugins/build)。

| 項目 | 公式仕様 | 本環境での判断 |
| --- | --- | --- |
| repo marketplace | `$REPO_ROOT/.agents/plugins/marketplace.json` | 新規Codex-first repoの正規path |
| Claude互換catalog | `$REPO_ROOT/.claude-plugin/marketplace.json` | 既存`gigun` catalogを複製せず共有可能 |
| personal marketplace | `~/.agents/plugins/marketplace.json` | user共通catalog向け |
| plugin manifest | `.codex-plugin/plugin.json` | Codexで公式保証を取るpluginには追加する |
| plugin contents | `skills/`, `hooks/`, `.mcp.json`, `.app.json`, `assets/` | MCPはroot `.mcp.json`へ分離すると中立化しやすい |
| install cache | `~/.codex/plugins/cache/<marketplace>/<plugin>/<version>/` | sourceを直読みせずcache copyを実行する |
| enable state | `~/.codex/config.toml` | repo catalogの存在はproject-only enableと同義ではない |

現在の`gigun` marketplaceはCodex CLIから直接列挙でき、`tableplus-mcp`、`markitdown-mcp`、
`ios-skills`、`workers-fetch`がinstall / enabledである。一方、各pluginは
`.claude-plugin/plugin.json`だけを持つ。これは互換実測としては有用だが、公式形への移行完了ではない。

### Symlink優先方針

- **そのまま共有:** `AGENTS.md -> CLAUDE.md`、repo `.agents/skills`からClaude側skillへのsymlink。
  Codex公式もsymlinkされたskill directoryを追従する。
- **共有しない:** plugin cache。cacheはinstaller所有であり、正典repoの代わりにしない。
- **段階移行:** marketplaceは既存legacy-compatible catalogを正典のまま使う。各pluginを触る際に
  `.codex-plugin/plugin.json`を追加し、共通設定をroot `.mcp.json`やskill directoryへ寄せる。
- **隔離検証が必要:** `.codex-plugin/plugin.json`自体のsymlink対応は公式記載を確認できない。
  複製を避けるために採る場合も、実user configへ入れる前に隔離`CODEX_HOME`でinstall / restart / tool実行を確認する。

Claude commands / subagentsの直接互換は現行Codex plugin構造に記載がない。commandsはskillへ、
agent規律は`AGENTS.md`またはskillへ意味を移す。Claudeのproject-only plugin enableと同じscopeも
公式資料からは確認できないため、repo固有MCPはproject `.codex/config.toml`を使う。

## 3. OpenAI公式Build iOS Appsの評価

公式source: [openai/plugins build-ios-apps](https://github.com/openai/plugins/tree/main/plugins/build-ios-apps)、
[pluginの`.mcp.json`](https://raw.githubusercontent.com/openai/plugins/main/plugins/build-ios-apps/.mcp.json)。

- `codex plugin add build-ios-apps@openai-curated`でinstall / enable済み。manifestは`0.1.2`、
  install cache revisionは`d6169bef`。
- MCPは`npx -y xcodebuildmcp@latest mcp`で、
  `simulator,ui-automation,debugging,logging`を広告する。
- bundled skillは`describe_ui`、`start_sim_log_cap`等を指示するが、固定版2.6.2の現行tool名・workflowと
  一致しない箇所をローカルprobeで確認した。
- `@latest`はinstall時点で挙動が変わり、skill本文と実serverの組合せを再現できない。

2026-07-23に新規`codex exec` sessionでstock `ios-debugger-agent`をロードし、専用Harness Bで
H-01を開始した。`codex mcp list`にはplugin由来の`xcodebuildmcp`がenabledで現れた一方、sessionには
XcodeBuildMCP toolsが公開されず、stock entryの`npx -y xcodebuildmcp@latest`確認は60秒無出力の後に
終了コード130となった。同じsessionで`No space left on device`が発生し、Data volumeは100%・空き
2.4 GiBだった。package実体もnpm cacheに無かったため、この結果は**環境阻害 / No score**であり、
pluginの機能不合格とは判定しない。plugin外fallback、build、Simulator操作、repo変更は行っていない。

同日、Data volume空き14 GiBへ復旧後にstock package取得を完走し、`@latest`が2.6.2へ解決する状態で
fresh H-01を再実行した。skillはロードできたが、Codex CLI 0.145.0は`tools/list`を30秒でtimeoutし、
必須MCP toolは0件のままだった。direct stdio probeではserverは約0.2秒でinitializeし、stock workflowの
`logging`をunknownとして無視したうえで44 tools / 約63,469 tokensのschemaを返した。したがって再試験は
環境阻害ではなく既定30秒のstartup deadlineで失敗したことまでは確定したが、schema量を単独原因、
0.1.2を互換性不合格と断定した判断は後続試験で撤回した。同一command / args / envへ
`startup_timeout_sec=120`だけを追加すると44 toolsが公開され、Harness Bへのbuild / install / launch、
49要素のsemantic snapshot、screenshotまでfallbackなしで成功した。macOS / Xcode許可promptも無かった。
その後Codex Desktopからpluginを有効化し、現在taskへskill群と`xcodebuildmcp`が公開された。
追加のstartup timeout設定なしでHarness Bへのbuild / install / launch（12.5秒）とK-01を完走した。
semantic refによるfield選択、日本語clipboard、誤URL、backspace、Select All / Paste、blur validation、
キャンセル後の未保存を確認したため、Desktopの探索E2Eへ**条件付き採用**する。
ただし`replaceExisting:true`は日本語IME下で文字化けしても成功応答を返したため、操作後のsemantic value確認を必須とする。
macOS / Xcode許可promptは無く、clipboard用`xcrun simctl pbcopy`だけCodex sandbox approvalが必要だった。
OpenAIの現行use caseも同じ原則を示す:
[Debug in iOS simulator](https://learn.chatgpt.com/use-cases/ios-simulator-bug-debugging)。

## 4. iOS agent検証の推奨階層

Appleはfastなunit/integration testを多く、遅いUI testを重要flowへ絞るtest pyramidを推奨する。
[Testing](https://developer.apple.com/documentation/xcode/testing)。UI回帰の正規層は
[XCUIAutomation](https://developer.apple.com/documentation/XCUIAutomation)であり、Accessibilityを使って
UIを操作・検証する。[Recording UI automation](https://developer.apple.com/documentation/xcuiautomation/recording-ui-automation-for-testing)
では、記録結果を意味的に安定したqueryへ直し、assertionを加えるworkflowが示されている。

| 層 | 役割 | 成功根拠 |
| --- | --- | --- |
| L0 `make check/app/verify` | unit、lint、全target compile | commandのexitとtest結果 |
| L1 Apple Xcode MCP | Apple docs、build/test、Issue Navigator、Preview | Xcodeのbuild/test/issue結果 |
| L2 XCUIAutomation | 合意済みnative UIの恒久回帰 | source-controlled assertion + xcresult |
| L3 simctl + idb | 汎用Simulator操作、WKWebView fallback | 明示UDID、AX tree、screenshot、状態再取得 |
| L4 固定版XcodeBuildMCP | semantic ref、入力訂正、log / debuggerを使う探索 | runtime snapshot sequence + log |
| L5 project `ios-e2e-verify` | OAuth、caldav、MCP Apps、JS状態 | screen + MCP結果 + unified log +再起動状態 |
| L6 実機 | Simulator差と配布物の最終確認 | build / install / launch、必要な人手触感 |

XcodeBuildMCP自身も、MCPで広告するworkflowを絞るほどcontextを節約でき、CLIは必要なcommandを
progressive discoveryできると説明する。
[Workflows](https://www.xcodebuildmcp.com/docs/workflows)、
[UI Automation](https://www.xcodebuildmcp.com/docs/architecture-ui-automation)。
常時36 toolを広告するより、MCPは必要最小限、稀な操作はCLIに逃がす方針を維持する。

## 5. Apple Xcode MCPのcapabilityと使いどころ

project `.codex/config.toml`の`xcrun mcpbridge`へ現在のCodex sessionから接続し、次を確認した。

- `XcodeListWindows`: `MCPHost.xcodeproj` / `windowtab1`を取得。
- `XcodeListNavigatorIssues`: Issue Navigator取得成功。
- X-01は**Pass**。Apple公式Xcode MCPはA〜DのSimulator比較と直交するIDE evidence層として採用する。

現在公開される20 toolsは次の責務に分かれる。

| 責務 | tools | 推奨する使いどころ |
| --- | --- | --- |
| Xcode context / navigation | `XcodeListWindows`、`XcodeLS`、`XcodeGlob`、`XcodeGrep`、`XcodeRead` | 開いているproject / tabを特定し、Xcode project navigator基準で対象を読む |
| build / test evidence | `BuildProject`、`GetBuildLog`、`GetTestList`、`RunAllTests`、`RunSomeTests` | current schemeのbuild、失敗log、Xcode test planの選択実行とxcresult相当の証拠取得 |
| diagnostics | `XcodeListNavigatorIssues`、`XcodeRefreshCodeIssuesInFile` | `make verify`後も残るcompiler warning、package / workspace issue、編集中fileの診断確認 |
| Apple knowledge / experiment | `DocumentationSearch`、`ExecuteSnippet` | Apple公式documentationのsemantic検索、target context内の小さなSwift式の検証 |
| visual design evidence | `RenderPreview` | SwiftUI Previewのbuildとsnapshot取得。実アプリE2Eの代用にはしない |
| project edit operations | `XcodeWrite`、`XcodeUpdate`、`XcodeMV`、`XcodeMakeDir`、`XcodeRM` | Xcode project organizationへの反映が必要な限定操作。通常のrepo編集は既存workflowを優先する |

`BuildProject` / `Run*Tests`はXcodeのactive scheme / destinationを使うIDE検証である。
SwiftFormat・SwiftLint・tracked pre-push hookまで含むrepo delivery gateは`make verify`のままとし、
Xcode MCPだけ通してpush可能とは扱わない。逆に`make verify`だけではIssue Navigatorのfresh warning 0を
保証しないため、delivery前は両方を見る。

Apple公式設定手順:
[Giving external agentic coding tools access to Xcode](https://developer.apple.com/documentation/xcode/giving-agentic-coding-tools-access-to-xcode)。
このMCPにはSimulatorのinstall / launch、runtime accessibility snapshot、tap / type / swipe、
Simulator log captureがなく、XcodeBuildMCPやsimctl+idbのruntime UI backendを代替しない。

Issue Navigatorはworking treeに次のwarningを報告した。

1. `InlineCardView.swift`: captured `self`がSwift 6 modeではerrorになる警告2件。
2. `AppsBridgeSession.swift`: async operationを含まない`await` 1件。

`make verify`成功とXcode compiler warning 0は同義ではない。Fableのdelivery前修正項目へ送る。

## 6. repoへ残る改善

- generic `ios-simulator`の例から曖昧な`booted`配送を外し、全工程を明示UDIDへ固定する。
- 固定`918px / 402pt / 2.284`は端末固有の観測例へ格下げし、実行時AX frameまたはscaleを正にする。
- 固定sleep中心ではなく、bounded poll → hierarchy再取得 → screenshotで状態を待つ。
- `MCPHostUITests` targetと安定したaccessibility identifierを追加する。最初はconnection validation、
  drawer/context menu、reparent spike、履歴revalidation gateを対象にする。
- live OAuth / caldav本番はflakyかつ副作用を持つためpre-push必須にせず、専用E2Eで維持する。

## 7. 調査環境への変更

`openai-docs` skillの公式source routeを満たすため、global Codexへ
`openaiDeveloperDocs` MCP（`https://developers.openai.com/mcp`）を追加した。repoのMCP設定は変更していない。
新しいsessionから公式OpenAI docs検索に利用できる。

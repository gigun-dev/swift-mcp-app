# 配送済み修正のcommit manifest

2026-10-03。親レビュー用の資料であり、stage/commit/pushは未実施。対象は0005/0006/0007/0009/0010の
失敗表示、失敗span、未完了stream、non-strict、OAuth保持。実機上書きinstall/launchは配送完了であり、
本人の利用報告と実trace照合（0011）は別の受入境界。性能0001/0002と中立契約0003の新実装は広げない。

## 保存と切り出しの前提

現checkoutはtracked差分42 filesと多数のuntrackedを持つ。untrackedには製品のResponses/OTel/Chat分割
実装も含まれ、未追跡だから不要とは判断できない。この資料では所有が明確な今回変更と、既存前提を区別する。
`git add .`、`git add -u`、全ファイル置換、reset/clean/stashは使わない。部分追加する場合も元checkoutを
保ったまま親が内容をレビューする。行番号は後続編集で動くため、下記の型/関数/文字列anchorでhunkを特定する。

以下は論理順序の案。既存基盤の所有確認・記録を先に済ませ、今回修正を載せる。各単位が独立build可能かは
隔離した候補treeで改めて確認する。現在の全dirty checkoutのgate成功だけで部分commitの依存充足を断定しない。

## A: OAuth再接続と一時失敗時の認可保持（所有: swift_performance_inventory）

現在のOAuth成果は以下の6ファイル＋専門docsで一つのcommitにまとめるのが最小。0009と0010を別commitに
するにはMCPConnectionを中間状態へ組み立て直す必要があり、配送済み最終状態だけを記録する今回は不要。

|file|今回の範囲/anchor|前提・検証|
|---|---|---|
|Sources/Services/MCP/MCPConnection.swift|`OAuthTokenStore.shared`、保存clientID復元の`tokenEndpointAuthentication`、`PreservingOAuthAuthorizer`、single-flight説明訂正|現在このfileのtracked差分は上記OAuth範囲。既存SDK/Keychain/proactive policyを保持|
|Sources/Services/MCP/ServerRegistry.swift|`remove(id:)`のshared store経由clearと説明|進行中refreshが削除tokenを復活させない|
|Sources/Services/OAuth/OAuthTokenStore.swift（new）|全体: URL別共有store、shadow transaction、世代guard、mutation gate|KeychainTokenStorageとSDK TokenStorageに依存。新OAuth protocolは不要|
|Sources/Services/OAuth/PreservingOAuthAuthorizer.swift（new）|全体: 標準HTTPClientAuthorizer wrapper、transient discard/success commit|SDK OAuthAuthorizerへ委譲。503/timeout旧token保持、invalid_grantは既存再認可|
|Tests/ServicesTests/OAuthReconnectRefreshTests.swift（new）|全体: loopback fixture、別storage instance＋新authorizer|保存clientIDでrefresh成功/DCR0/browser0、初回認可、有効token、503、timeout再試行、invalid_grant|
|Tests/ServicesTests/OAuthTokenTransactionTests.swift（new）|全体: clear/save競合、直列rotation、registry remove|成功競合はCancellationError、rollbackで明示clear/新saveを復活・上書きしない|
|docs/design/08-oauth-token-lifecycle.md|2026-10-03追補9行|既存本文を保持|
|docs/benchmarks/2026-10-03-oauth-reconnect-refresh.md（new）|全体|実機配送済み/自動UI不要、4xxと永続化限界を含む|

検証: `/tmp/swift-oauth-transaction-make-check.log`でServices201/Kernel136 tests、known issue0、lint183 files
違反0。親レビュー済み後、同一iPhone17 moritaへfresh DerivedData `ios-device-derived-data.Bf0P4G`で
build/install/launch成功。SDK source、KeychainTokenStorage、実token、認可状態に変更は加えていない。
TokenStorage.saveのvoid境界によりKeychain永続化成功はcommit戻り値だけでは証明できない。429等の全4xx
分類・backend側rotationの取消しは未解消。この制限を完了説明から削除しない。

## B: non-strict schemaと未完了stream（今回所有:親のstream/schema担当）

|file|今回hunk anchor|混在する既存差分/依存|
|---|---|---|
|Sources/Kernel/LLMProtocol/ChatCompletion.swift|`ToolDefinition.Function.encode`の`encode(false, forKey: .strict)`＋`ToolFunctionCodingKeys.strict`|reasoningEffort、PromptTokensDetails/Usage追加は既存性能/推論選択前提。今回strict hunkに混ぜない|
|Sources/Services/LLM/OpenAICompatClient.swift|終端の`guard done || completion.finishReason != nil`、`LLMClientError.responseError`とdescription|TTFT events、payloadMetrics、大きなSSE parser/accumulator差分は既存基盤。関数単位切り出しにも前提確認が必要|
|Sources/Services/Chat/ChatCompletionStreamConsumer.swift|finishReason optional化、`Task.checkCancellation`、completedなしEOFでthrow|response/output/text timestamp計測は既存性能前提。LLMClientError追加と対にする|
|Sources/Services/LLM/OpenAIResponsesClient.swift（new）|`strict:false`、`guard completed`、response.failed/incomplete/error|file全体は既存Responses実装。今回hunkだけではHEADへ追加できないため基盤commitに全体を記録後修正するか、親が履歴を明示して同じ単位へ含める|
|Tests/ServicesTests/SchemaAndStreamBoundaryVerificationTests.swift（new）|全体: optional schema/両adapter/EOF/通信断fixture|MCP、両client。`BoundaryStreamServer`はToolFailureLoopVerificationTestsからも使うので片方だけ欠落させない|
|Tests/ServicesTests/LLMTests.swift|EOF/DONE/finish_reason/取消の追加回帰|同fileの性能/usage/metadata回帰は既存dirty。hunkを確認|

## C: MCP論理エラー表示と失敗span（今回所有:親のtool failure担当）

|file|今回hunk anchor|混在する既存差分/依存|
|---|---|---|
|Sources/Services/Chat/ToolCallRunner.swift|`executeValid`の`isError`と`failed: isError`|llmContent縮約、完全step保存、durationMs、mcp.tool.outputは既存性能/OTel基盤と同hunkに混在。全hunk追加は今回修正だけにはならない|
|Sources/Services/Chat/ChatViewModel.swift|反復上限後`chat.turn.output`のerror/level|大きなCompletion/TurnActions/Inference分割、performance、trace context、復元経路変更は既存前提|
|Sources/Services/Observability/OpenTelemetryService.swift（new）|`chat.turn.output` level.errorでparent Error、`turnSettled`でunsetだけOK、generation errorで失敗|全体は既存OTLP基盤。Bと同様、new fileの部分差分だけをHEADへ独立追加できない|
|Tests/ServicesTests/ToolFailureLoopVerificationTests.swift（new）|全体: logical error、反復上限、回復後OK、EOF失敗span|ScriptedLLMClient/StubToolExecutor（既存ChatViewModelTests）、BoundaryStreamServer（B）、OTLP SDK exporter common|
|Tests/ServicesTests/TelemetryFailureVerificationTests.swift（new）|全体: HTTP530/失敗OTLP batch再送|OTel/router基盤。B/C本体の最低限とは別の追加観測回帰としてレビュー可能|
|docs/benchmarks/2026-10-03-tool-failure-and-stream-verification.md（new）|検証・制限・配送の記録|末尾の旧「起動保留/0008 WIP」はAの後続launch成功と矛盾。親統合記録時に配送済みへ訂正する|

B/C検証記録: `/tmp/swift-mcp-final-check-20261003-r2.log`（Services188/Kernel136）、
`/tmp/swift-mcp-final-app-20261003.log`。後続Aの全gateも成功。実機配送はB/Cを含む現在のcheckout全体。
元端末-1005原因特定を、synthetic通信断再現やEOF修正成功と混同しない。

## 必要な既存基盤のclosure（所有を確認してから別単位へ）

現在のcheckout全体を再現する場合の主要前提。ここを今回所有成果と断定しない。

- Responses/方式選択: OpenAIResponsesClient、LLMAPIStyle、LLMProviderRegistry、
  Features/Chat/ChatHomeViewModel+LLMClient、SettingsSheet+APIStyle、LLMSettingsStoreと対応回帰。
- OTel: Package.swiftの2packages/3productsとPackage.resolved、OpenTelemetryService、TelemetryPort、
  OSLogTelemetry、TraceSink、TelemetrySettingsStore、ChatHomeViewModel/SettingsSheetのcomposition、
  ADR0001/0003、OpenTelemetryRouterTests。Package lock全差分は新packageだけでなく既存pin変化もレビューする。
- Chat分割/性能: ChatViewModel+Completion/+TurnActions/+InferenceSelection、ChatPerformanceAccumulator、
  RestoredWireHistoryBuilder、LLMClient responseStarted/outputStarted、OpenAICompatClient.payloadMetrics、
  ToolCallRunner duration/full-result/text、PermissionGateのExecution初期化、ChatModel追加値、PricingStore、
  RetryPlannerと対応Tests。現ChatViewModelがこれらを呼ぶためnew extensionの欠落はbuild失敗になる。
- 現配送UIを同じ状態で再現するなら、ChatPerformanceView/LLMSelectionView/ChatTopToast等のnew Viewsと
  使用側Features差分も前提。今回修正のため必須かは隔離候補treeのiOS buildで確定する。

## 今回追加の検証・整理資料（製品修正と分ける）

MCPResultPayloadBenchmarkTests、2026-10-03-mcp-result-payload-baseline.md、
docs/design/10-provider-neutral-conversation.md、本manifestは調査/検証単位。
UITests/DeviceReadOnlyChatUITestsは準備済みだが実行未成立・ユーザー指示で再開不要。配送済み修正の成功を
裏付ける実機受入テストとして扱わず、必要なら別の検証用commitへ分ける。
todo.txt/done.txtは新規の全タスク台帳であり、既存ADR/docs/log/docs/next-directionsも複数時期の記録を含む。
台帳導入と今回完了記録を親が別単位でレビューする。0001/0002は未完のままstop済み、0003は未着手。

## 無関係dirtyの保護

MapPreview配下、docs/design/native-map-preview.md、project.ymlのMapPreview resources hunk、
docs/demo-media/mcphost-tomorrow-agenda-demo-20260802.mp4、tmp-demo/は今回修正対象外。
その他ジェスチャ、スクロール、selectable bubble、card表示、履歴操作、設定UIの差分も今回成果として
一括stageしない。既存担当の意図を確認し、上記closureとして必要な箇所だけ別単位に入れる。
ignoredの.build証拠、device DerivedData、.xcresult、/tmpログ、生成.xcodeprojはcommit対象外。

親がcommit候補を確定したら、候補treeでmake checkとiOS buildを行い、untracked依存欠落を検出する。
その後に配送済み成果の記録をcommitする。本人の利用報告・復旧後実trace照合は0011に残し、
新性能実装やprovider契約変更を完了条件へ追加しない。

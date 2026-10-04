# 接続断とツール失敗反復の切り分け（2026-10-03 JST）

## 実端末の証拠

Langfuseの実データを取得。trace d7a55ab2b23e2df0e3a015f74fb93e91 は 00:33:26.771〜00:34:18.275、約51.5秒。list-events-expanded 6件すべて isError:true。range=today と timeMin/timeMax の空文字が併記され、サーバーが相対・絶対範囲の同時指定として拒否。同じ失敗が反復した。get-current-time は成功。最後のLLM generationとchat.turnは NSURLErrorDomain -1005 の ERROR として保存済み。画像の実行時間とエラー内容が一致。

これだけでは誤引数がモデル単独、bridgeのschema変換、両者の組合せのどこで生じたかは確定できない。20:31画像の反復上限については該当実トレース未照合。

## 自作ホストの決定的検証

Tests/ServicesTests/ToolFailureLoopVerificationTests.swift：2件実行、known issue 2件、5.186秒。SwiftFormat/SwiftLint違反0。

- MCP isError:true をUIが doneとして表示する。望ましいfailedをknown issueとして検出。
- 同じ不正引数を返すstubモデルでは8回実行して上限で停止。
- 次のLLM requestには全ての前周tool結果がcall ID/JSON内容一致で渡る。結果の渡し忘れはこの再現系では否定。
- OTLPを実受信し、tool Error span8件を確認。一方、反復上限chat.turnはOK。望ましいErrorをknown issueとして検出。

## 通信経路の実試験

モデル gpt-5.6-luna、Reply exactly OK.、stream=true、ツールなしの短いChat Completionsを使用。

|経路|結果|所要時間（秒）|
|---|---|---|
|VM loopback 127.0.0.1:18080/curl|3回とも200・DONEまで受信|2.981 / 1.742 / 6.148|
|VMから公開codex URL/curl|3回とも200・DONEまで受信|5.180 / 3.818 / 2.210|
|このMacから公開codex URL/Swift URLSession.bytes|3回とも200・DONEまで受信|3.991 / 1.865 / 1.794|

Python urllibの公開URL試験はCloudflare 1010/403で拒否されたため、ストリーム性能比較から除外。Swift/curlとのクライアント差があり、実端末の-1005とは区別する。mini-vmへの直接SSHが一時タイムアウトしたが、mini経由limactl shellで到達でき、bridgeとnamed tunnelはactive。該当時刻のtunnel journalには記録がなく、切断原因を断定する証拠なし。

短い通信が成功した事実は、実端末の回線・長時間stream・tool履歴付きrequestでの接続断を否定しない。

## ChatGPTホスト比較

アプリ内ブラウザのChatGPTで同じCalDAVに「今日の予定、Asia/Tokyo、作成・変更なし」を依頼。応答完了し、予定なしのカレンダーカードも表示。会話 https://chatgpt.com/c/6abfd051-d8e0-83ee-98c6-faebf20f242d 。

CalDAVとMCP Appsが他ホストで動く比較証拠。モデル・prompt・tool schema変換が同一ではないため、Swiftだけが誤引数の発生源とは断定しない。

## 未完了

- 実端末の-1005：長時間stream/同じ履歴と回線条件の再現、および切断前後のrequest相関。
- モデルが空文字の任意引数を繰り返す理由：bridgeへ送ったschemaとupstreamに渡したschemaの比較。
- UIのisError表示、反復打切りspanのError化の修正と回帰確認。

アプリ実装、サーバー設定、deployは変更していない。新規検証テストだけ追加。

## 同日追検証・ホスト修正

上記は修正前の記録。以降の修正では `ToolCallRunner` が `isError:true` を表示用 `.failed` に反映し、
`ChatViewModel` が反復上限の理由を `chat.turn.output` へ渡す。OTLP adapter はその Error を
`turnSettled` で OK に上書きせず、反復数と usage を残して終了する。個別ツール失敗だけでは親を
Error にせず、モデルがその後 `.stop` に到達した会話は OK とする。UI レイアウト変更はない。

`ToolFailureLoopVerificationTests` の known issue 2件を通常の検証へ変更。完全な
`content` / `structuredContent` / `isError` / `_meta` の表示履歴・LLM再入力、失敗時のカード抑止、
8回打切りの tool Error 8件と会話 Error、成功・失敗後の回復・最終許容反復での `.stop` の会話 OK を
OTLP 実受信で確認した。結果の渡し忘れを原因とする証拠はない。

検証: `make check` 成功（Services 186 tests + Kernel 135 tests、SwiftFormat/SwiftLint 違反0）、
最終ソースで `make app` 成功。実端末・Simulatorでの画面確認と本番接続再現は未実施。
実装は subagent `fix_tool_failure`、追加調査は `investigate_stream_schema`、親が差分レビューと総合検証を担当。
既存dirtyを保護し、今回の実装変更は Services の上記3ファイル、既存検証テスト1ファイルと新規境界テストに限定。
stage / commit / push / deploy / 実ホスト停止は行っていない。

## 同日追検証・schema と長時間通信

`SchemaAndStreamBoundaryVerificationTests.swift` は MCP Tool の任意引数を含む fixture を
`toolDefinitions` / `prefixedToolDefinitions` から Chat / Responses の送信 JSON へ通し、
`parameters` が元の schema と一致することを検証した。Chat の `strict` は未指定、Responses は
`strict:false`。ホスト側のこの変換で任意引数を required 化する挙動は確認されない。
実端末で使われた実 schema や、公開 bridge から upstream への変換を証明する試験ではない。

ローカル TCP server と両 adapter の実 `URLSession.AsyncBytes` を使う。通常 gate は短時間、
`MCPHOST_VERIFY_STREAM_SECONDS=65 swift test --filter SchemaAndStreamBoundaryVerificationTests`
で長時間試験を明示実行した（65.149秒、成功）。

|条件|Chat Completions|Responses|
|---|---|---|
|65秒継続、16.25秒ごとの heartbeat、明示的完了|65.031秒・completed 1件・エラーなし|65.027秒・completed 1件・エラーなし|
|Content-Length未達でTCP切断|NSURLErrorDomain -1005・completedなし|NSURLErrorDomain -1005・completedなし|
|完了イベントのない正常HTTP EOF|エラーなし・completed(no_finish_reason)|LLMClientError・completedなし|

切断時の `-1005` は通信異常が完了へ変換されないことを示すが、実端末の切断原因とは同定できない。
65秒成功はローカルでデータが継続到着する条件だけの証拠で、無通信60秒・公開 tunnel・upstream・
端末回線・background状態を検証していない。

Chat の正常 EOF は `OpenAICompatClient.consumeSSE` が `.other("no_finish_reason")` を返し、
`ChatViewModel.send` が非toolCallsとして settle する既存動作。Responses は
`response.completed` がなければ例外にする。この差は別タスク（0006）として残す。

実稼働 VM の `/run/codex-bridge/version` は読み取りで 0.2.1 を確認した。
uv cache に見つかった Python 変換コードは METADATA が 0.1.4 のため、現行 upstream 変換の証拠から除外。
実ホストの設定・稼働状態は変更していない。

### 稼働版と対応する公開sourceの追加確認

実プロセスの exe は uv archive の `openai_api_server_via_codex/bin/openai-api-server-via-codex`、
同じ site-packages の METADATA も 0.2.1 と一致。公開 repository の v0.2.1 tag
（commit `12053383bf000940523332173458a4a094f50b0c`）を一時cloneし、変換関数を実行した。
これは version が対応する source の検証であり、稼働 binary の実際の upstream request capture ではない。

[`compat.go` 213–221行](https://github.com/hotchpotch/openai-api-server-via-codex/blob/12053383bf000940523332173458a4a094f50b0c/internal/app/compat.go#L213-L221)
の Chat function 変換は function object をcloneして `type:function` を加える。`parameters` や
`required` を書き換えず、`strict` 省略もそのまま。source関数の最小 fixture（3 cases、Go test 0.499秒）で
Chat省略→省略、Chat false→false、Responses false→false、全ケースschema完全一致を確認した。
[`backend.go` 147–150行](https://github.com/hotchpotch/openai-api-server-via-codex/blob/12053383bf000940523332173458a4a094f50b0c/internal/app/backend.go#L147-L150)
は payload を JSON encode して Codex の HTTP `/responses` へ送る。

したがって、Swift Chat経路は `strict` 省略、Swift Responses経路は false明示という違いがある。
[OpenAI公式のResponses移行ガイド](https://developers.openai.com/api/docs/guides/migrate-to-responses)
§5では、Chat既定はnon-strict、Responsesは省略時にstrict化を試行し互換不能ならnon-strictへfallback、
non-strictを維持するにはfalseを明示する、と説明されている。
**inferred:** この省略差は空文字placeholder生成の調査候補となる。ただし公式APIとCodex内部が同じ挙動か、
実端末の誤引数に因果があるかは未検証。推測だけでホストの送信契約は変更していない。

未完了（0004）: 実稼働 upstream の `tools[].strict` / schema を captureし、同モデル・promptで
省略とfalse明示を対照すること、および同じ tool 履歴・回線・端末状態での切断前後の request 相関。
空文字引数の発生源も未確定。
失敗表示・上限 span 修正（0005）は総合検証を含め完了。

## 同日継続・公開bridge対照と修正（0004から0007へ分離）

公開 `https://codex.097969.xyz/v1/chat/completions`、稼働bridge 0.2.1、モデル `gpt-5.6-luna` に
同じprompt・任意引数schemaを送った。CalDAV本番は呼ばず、hostと同じtool call/resultの履歴を
合成fixtureで積み戻す。次の結果は元の実端末traceそのものの再実行ではない。

|条件|初回|tool結果を返した後|
|---|---|---|
|strict省略・3 samples|3/3でrange=todayとtimeMin/timeMax空文字を併記|省略するよう伝えるisError結果を戻しても6/6呼出しで反復|
|strict:false・3 samples|3/3で時刻の任意キーを省略|成功の合成結果から3/3最終回答へ終了|
|省略条件と同一の失敗履歴、strictだけfalseへ変更・3 samples|—|3/3で問題のキーを省略して修正|

全18リクエストがHTTP200・DONE。**この合成再現ではstrictの省略／falseが空文字引数反復を
生じる差として確認できた。** サーバーが返した失敗結果はモデルへ渡っており、渡し忘れではない。
Codex内部のschema正規化や、元端末の実requestとの一致まで証明する結果ではない。
21リクエスト分のupstream payloadはv0.2.1実source関数の出力として保存し、稼働TLSの直接captureと区別した。

`ToolDefinition.Function.encode` に標準 `strict:false` を明示し、既存Responses adapterと契約を揃えた。
MCP schema・required・任意引数を変更せず、public API・decoder・vendor分岐を増やしていない。
legacy decode、annotations内部保持とwire除外、両API schema一致、実HTTP bodyのfalseを回帰確認した。
この完了部分を0007へ分離し、0004には実端末切断だけを残した。

## 同日継続・実公開経路の長時間通信

同じ合成tool結果履歴とtools定義を含む公開streamを測定した。長文量はcurlが750行、Swiftが500行の
指定で異なるため、速度優劣の比較には使わない。TTFTは最初のSSE dataで、最初のtext tokenとは限らない。

|経路|完了|時間|TTFT|最大data event間隔|受信|
|---|---|---:|---:|---:|---|
|Mac curl・tool履歴あり|HTTP200・DONE・curl0|118.697秒|8.974秒|2.669秒|5,940 events、24,761文字|
|Mac Foundation URLSession.bytes・同tool履歴|HTTP200・DONE・例外なし|81.080秒|1.553秒|1.773秒|4,334 events、4,331 text delta、1,045,256 bytes|

Swiftはアプリと同じ request timeout60秒／resource timeout300秒、生byte→LF分割を用いた。
ローカル65秒だけでなく公開bridge＋履歴＋Foundationでも長時間streamが通ったが、実端末の
回線・background・元traceの正確な履歴までは再現していない。実端末 `-1005` は未特定のまま。
別の1,800行試験は240.014秒の自前検証上限でcurl28となり、約3.09MBを受信したがDONE未受信。
自前上限を接続断や `-1005` と呼ばない。

利用可能なLangfuse CLIの複数projectでは既知trace IDの再取得が0件だった。v2 profileの最新データは
9月26日の別観測で、元端末projectとの一致を確認できない。この検索を元traceの不存在や問題解消の根拠とせず、
冒頭の元trace情報は前回取得記録として維持した。

## 同日継続・専用iOS Simulatorの通常チャット検証（0005）

専用 `w-tool-failure-20261003`、iPhone17 / iOS27を作成し、preflight後に明示UDIDで署名build/installした。
空のserver登録簿とlocalhost OTLP、偽LLM keyから開始し、通常設定UIでローカルMCPを登録して通常Chatを送信。
実CalDAV・実モデルを使う試験ではない。既存端末の設定や資格情報は変更していない。

- Recover: `isError:true` のツール行は赤い×、最終回答 `Fixture recovery finished.` を表示。
  同じturnのOTLPは `chat.turn` OK / iterations2、子ツールError。次LLM要求に元結果を再入力。
- Repeat: 赤い×8行と「ツール呼び出しが最大反復(8回)を超えたため打ち切りました。」を目視・AXで確認。
  OTLPは会話Error / iterations8、子ツール8件Error。unified logも同一turn IDで一致。

スクショは検証agentが開いて確認した。fixtureの明示的finish_reasonとDONEを通す試験で、WKWebViewカードや
本番接続は対象外。一時server停止、専用Simulatorのshutdown/deleteを完了した。

## 同日継続・EOF誤成功の修正（0006）と最終gate

Chatの正常HTTP EOFでもfinish_reasonとDONEが両方無ければ、未完了エラーへ送るよう修正。
中立consumerもcompleted未受信のEOFをエラーにし、キャンセルは従来どおりUIエラー無しに区別する。
表示済み部分textを保持し、不完全toolを実行せず、generationと会話spanをErrorにすることをOTLP実受信で検証。
finish_reasonだけ・DONEだけ・末尾改行なしDONEの互換と、通信断 `-1005` を維持した。

最初の総合testは即TCP切断時の「probe本文が必ず配送される」というfixture期待で1件失敗した。
URLSessionは本文通知前に通信断を返せるため、truncatedだけ空／probeを許容し、completed無しと
URLError.networkConnectionLost（-1005）を必須に強化。受信済み本文保持は決定的consumer fixtureが担当する。

最終 `make check` 成功: Services188 tests + Kernel136 tests（324 tests）、SwiftFormat/SwiftLint違反0。
最終製品ソースで `make app` 成功、`git diff --check` / `todo check` 成功。
実装はsubagent fix_tool_failure、公開通信はinvestigate_stream_schema、Simulatorはsimulator_operator、
親が設計・差分レビュー・総合gateと記録を担当。0005/0006/0007完了、0004は実端末条件のrequest相関が残る。
commit・push・deploy・本番設定変更・実端末install/launch/停止は行っていない。

ローカル証拠（git ignored）:

- `.build/verification-20261003/simulator-evidence.md`、スクショ2枚、`wire.jsonl`、`unified.log`、OTLP原本とdecode。
- `.build/verification-20261003/live-bridge/experiment-summary.md`、`aggregate.json`、21件のrequest/SSE/summary、
  source-predicted upstream、Swift scriptと同公開長時間streamのsummary。
- 最終gateログ: `/tmp/swift-mcp-final-check-20261003-r2.log`、`/tmp/swift-mcp-final-app-20261003.log`。

## 同日追加・CalDAV実schemaの別担当証拠との照合

[CalDAV側の追検証記録](/Users/gigun/ghq/github.com/gigun-dev/caldav/docs/monitoring-follow-up-2026-10-03.md)と
`docs/verification/2026-10-03-range-model-results.ndjson` / `2026-10-03-range-model-contract-checks.json` を
実読して件数と引数を照合した。公開schema／説明文修正後schemaそれぞれで、同prompt・gpt-5.6-luna・
strict省略／falseを各3件、計12件。省略6件すべてが空timeMin/timeMax併記でlocal MCP拒否、
false6件すべてがキー省略でlocal MCP成功だった。保存schemaは任意stringを維持し、requiredキーは省略されている。
別担当の修正エラー履歴対照でも、省略は反復、falseはキー省略。**説明文・エラー文だけでは解消していない。**

さらに、CalDAVの `scripts/verification/bridge-range-probe_test.go` を一時cloneへコピーし、
v0.2.1 commit `12053383bf000940523332173458a4a094f50b0c` の公開HTTP handlerからmock upstreamの
`/responses` まで再検証した。local／公開 × 3ツール × Chat省略／Chat false／Responses falseの
**18/18成功**（test0.02秒、package0.874秒）。schemaは完全一致、Chat省略は省略を保持、falseはfalseを保持。
本番bridgeの稼働TLS captureではなく、同version sourceのHTTP境界での確認である。

結論: 別担当の実CalDAV schemaによる結果は、こちらの公開bridge合成対照と一致する。
Chat経路の標準 `strict:false` 明示は既に実装済みで、既存の実HTTP body回帰も通っている。
モデル名分岐やCalDAV入力の自動補正は不要。実schemaでも説明文変更だけに依存せず非strictを明示する
修正が妥当と確認した。元実端末traceの単独原因、稼働binary request capture、実端末受け入れは未証明のまま。
この照合では製品source変更・live API再試行・push/deploy・本番変更を追加していない。

## 2026-10-03 実機への反映と後続の配送完了

ユーザー承認で、有線のiPhone17 morita（00008150-000964443A88C01C）へfresh DerivedData
`.build/device-accepted-20261003-02`でbuild・署名installに成功した。既存アプリを削除せず、
設定・Keychainへの操作もしていない。起動はOS Locked（FBSOpenApplicationErrorDomain7）で拒否され、
この時点ではprocess未確認だった。後続のOAuth修正を含むfresh DerivedData
`ios-device-derived-data.Bf0P4G`から同端末へ上書きbuild/install/launchが成功し、todo0008は完了した。
実機自動UI試験はユーザーの裁定で再開不要。ロック解除の維持を本人へ求めない。
Xcodeの実機interaction sessionは対象UDIDを拒否し、画面取得は未実施。Simulator受け入れ結果とは区別する。
証拠: `.build/verification-20261003/device/device-evidence.md`、build/install log・installed app readback・
source fingerprints・署名receipt。commit/push/deploy/CalDAV本番変更なし。

## 接続断を継続観察するための残件

`NSURLErrorDomain -1005` は通信中の接続喪失であり、HTTP 500とは別。合成通信断の回帰成功だけでは実端末で繰り返す原因を特定できない。

現在のgeneration span開始時にはmodel / turn_id / generation_id / request_index / phaseがある。正常終了ではresponse wait / TTFT / durationを記録するが、失敗時はエラー文字列のみ。NSError domain/codeの独立属性、provider/API方式、失敗時点のstream段階・途中出力までの時間・経過durationが揃っていない。文字列からコードを探すことと、安定した集計属性として比較できることは区別する。

次は復旧後の既存traceで取得範囲を確認し、不足属性を最小限補う。エラー件数・成功率・通信段階・モデルごとの偏りから対策を選ぶ。再現するたびに本人へ端末操作を求めることを既定の進め方にしない。本人が実施済みの操作と、復旧確認の合成probeも分ける。


## 復旧後の実トレース照合と失敗属性の配送

VMの稼働設定にある初期projectの資格情報を使い、`http://mini-vm:3000`の`langfuse-cli api observations list`で2026-10-02 00:00 UTC以降を全ページ取得した。22 observations、1ページ、打切りなし。通常のローカルprofileは別projectで12件、旧selfhostは0件、cloud profileも別用途だった。profileの検索結果0件を端末トレース不存在とした前節の問題を、正しいprojectとの照合で解消した。鍵・本文・raw payloadはGitへ保存しない。

実機の会話は3 traces。00:08 JSTのHTTP530、00:33〜00:34 JSTの既知trace `d7a55ab2b23e2df0e3a015f74fb93e91`、01:39 JSTの成功を再取得した。ERROR10件はHTTP530のgeneration/turn各1、同じ不正引数のtool6件、-1005のgeneration/turn各1。最後の失敗generationは2.211秒、会話全体は51.504秒だった。既存失敗はerror文字列のみで、headers前か途中出力後かをこの記録から断定できない。18:03/18:53 JSTの復旧・運用probeを除き、新版実利用traceはこの取得時点で見つからない。旧版の少数標本から新版の失敗率や安定性は判断しない。

`GenerationFailureTelemetry`でNSError domain/code/type、失敗段階、経過時間、観測済みheaders/first output/first textの時刻を追加した。段階はclientイベントの到達位置であり、回線・Tunnel・providerの原因を断定するものではない。HTTP非2xxはstatusを記録する。部分本文と取消し非表示を維持し、再試行や監視基盤を増やしていない。

独立したtracked checkoutで`make verify`成功（Services204 tests、Kernel136 tests、lint183 files違反0、generic iOS Simulator build成功）。-1005の5段階、単調時計の計測、HTTP530、取消しの回帰を確認した。実Swift exporterのHTTP530 fixtureを受信したprotobufに検証用environmentを付け、公開OTLP入口へ送信してHTTP200を確認。CLIでtrace `b48a97f29c0ad32cfb82fb823bf5b0ee`の2 spansを再取得し、`environment=verification`、`verification.synthetic=true`、generation ERROR、failure_stage=http_error、HTTP530、error.type=530、duration_ms=15を照合した。これは合成試験であり実機障害の発生記録ではない。環境属性は[Langfuseの公式仕様](https://langfuse.com/docs/observability/features/environments)に従った。

ios-device-build skillで列挙・dry-run後、同じ明示引数でiPhone17 morita（既存bundle `dev.gigun.mcphost`）へ新しいDerivedDataからビルド・上書きinstall成功。起動・自動UI操作・質問の再送信はしていない。配送証拠は `/tmp/swift-failure-observability-device.json`。他所有のMapPreview/project.yml変更は含めず保持した。

残る確認は通常利用で新属性が自然に保存されることと、その記録を基にした接続断の傾向。本人への再現操作の要求や、合成失敗を実利用の改善証拠に置き換えることはしない。

## 新版の通常利用・22:49 JSTの予定取得

同じ初期projectを2026-10-03 13:00 UTC以降で再取得し、12 observationsを照合した。検証用environmentの合成失敗とは別に、本人の「今日の予定」2 turnが保存されていた。両方とも`gpt-5.6-luna`、generation/tool/turnは成功、`list-events-expanded`の結果は予定なし、最終回答も予定なしだった。鍵・会話原本はGitへ保存しない。

| JSTの開始 | trace | turn全体 | 最初のmodel出力 | 最初のgeneration全体 | CalDAV tool | 後続generation全体 | hostのcard構築 |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 22:49:13.092 | `0719ece25f218c861316957d13623dc9` | 14.371 s | 8,752 ms | 9,489 ms | 200 ms | 4,675 ms | 311 ms |
| 22:49:35.677 | `9814f51fa490850e40382dca64324b85` | 13.188 s | 7,391 ms | 8,943 ms | 125 ms | 4,115 ms | 181 ms |

後者は本人画面のfirst model response約7,392 ms / tool125 msと一致する。最初のmodel出力はtool-call開始を含み、最終回答が読めるまでの時間ではない。最初のgenerationではheadersまで6,655 ms、headersから出力まで735 ms。後続はheadersまで3,119 ms、初出力まで3,690 ms。hostカード構築はtool終了33 ms後に始まり、後続generationと並行している。今回の長い待ち時間はLLM HTTP/SSE待ちにあり、tool125 msだけを改善しても3秒目標には届かない。

各generationへ25 tools、tools JSON62,255 bytes（schema JSON47,144 bytes）を送っている。後者のinput tokensは初回14,808、後続15,047。入力が大きいことは観測できるが、2件の同モデル標本だけではレイテンシの原因と断定できない。次の性能検証は既存0001のtool結果縮約と必要なtool定義の選択を同条件で比較する。provider modeをこの結果だけで変更しない。

`card.render`は`InlineCardView.swift:250–263`でsession開始・webView公開・初期payloadの送信／enqueue後に終わるため、JSのinitialized受信や背景calendar取得完了までの時間ではない。`InlineCardHost+HistoryRevisit.swift:18`はtool input→resultを自動配送し、`AppsBridgeSession.swift:301–306,358–366`はinitialized後にFIFOを配送する。selectorのtapを初期配送条件にはしていない。初期0からtap後に2色となる表示について、CalDAV担当がcalendar取得後の再描画欠落を特定した。Swift host変更は行わず、カード側修正の本人受け入れと区別する。

0018の「新版の通常利用trace保存待ち」は解消した。自然発生の接続断はこの2 turnにはなく、新しい失敗段階属性による原因傾向や失敗率はまだ評価できない。0011は本人の予定取得を実OTelで確認できたが、todo取得と本人による表示の受け入れは別の残件である。今回source変更・新しい監視・追加の実機操作は行っていない。

## 2026-10-04 制御した接続断の実OTLP保存（0018）

`TelemetryFailureVerificationTests.realConnectionLossIsExportedWithStageAndErrorParent` はChat Completions / Responses両adapterの実URLSessionへSSE本文を送り、200 ms後にContent-Length未達で接続を閉じる。stubのURLErrorではなくOSが返す`NSURLErrorDomain -1005`をChatViewModelから公式gzip/protobuf exporter、loopback HTTP receiverまで通した。両方式で部分本文`probe`、generation / 親turnのERROR、trace/parent相関、モデル、独立したdomain/code/type、`streaming_output`、headers/初出力/初本文の観測時刻、失敗時の経過時間を確認した。既存HTTP530の配送・再送試験も成功（2 tests / 3 cases、20.476秒）。製品ソースは変更していない。

受信protobufに公式の`deployment.environment.name=verification`と`verification.synthetic=true`を付け、稼働VMのLangfuse OTLP入口へ送信した（各HTTP200）。初期projectをCLIでtrace ID指定して再取得し、各generationとturnの2 observationsが保存されていることを確認した。

| API | trace | 失敗時経過 | generation / turn | 保存された分類 |
| --- | --- | ---: | --- | --- |
| Chat Completions | `910858c7f7630262296d00cb8dc79bb7` | 225 ms | ERROR / ERROR | NSURLErrorDomain / -1005 / streaming_output |
| Responses | `cc137adeb169fe026ed5176752d839fa` | 204 ms | ERROR / ERROR | NSURLErrorDomain / -1005 / streaming_output |

両方とも`model=disconnect-verification-model`、`environment=verification`、合成印、親observation IDが一致。これはMac上の制御試験であり、実iPhoneでの自然発生接続断・原因・失敗率やCloudflare公開入口の配送を証明しない。自然発生時には同じ分類と経過を使って比較できるが、この合成2件を実利用の安定性改善として数えない。原本・CLI readbackは一時検証ディレクトリに保持し、鍵・raw payloadは公開Gitへ入れない。

関連する失敗分類・実TCP終端・ツール失敗ループの回帰は9 tests / 3 suites成功（36.127秒）。変更したSwiftファイルのSwiftFormat lint / SwiftLint strict違反0、`git diff --check`成功。依存は既存キャッシュのcopy-on-write複製を使ったため、clean cloneの依存解決成功を示すものではない。製品UIを変更していないため、この試験で実機操作や新ビルドの配送は行っていない。

## 2026-10-04: カード削除後のpending解除

Swift `37492ee` とCalDAV `70a06c7` のカードで、以前報告されたdelete-todo応答後のspinner固着を再確認した。
実際のCalDAV HTML／ext-apps SDKをmacOSのWKWebViewへ読み込み、本番の
`WebViewTransport` → `AppsBridgeSession` → passthrough dispatcherを通した。
proxyのみ手動開放のfixtureへ差し替え、削除応答を待っている状態と応答配送後の状態を観測した。
カードの処理は変更せず、検証用bundleに状態読取とdeleteTask呼出の入口だけを追加した。

| 応答 | 応答前 | 応答後 | 表示 |
| --- | --- | --- | --- |
| 成功、tasks空 | pending=1、optimisticDeletes=1 | 両方0、confirmedTasks空 | 削除した行がない |
| CallToolResult.isError | 同上 | 両方0、confirmedTasksに元の行 | 行が復元され、削除失敗／再試行バナー |
| proxyがURLError.networkConnectionLostをthrow | 同上 | 両方0、confirmedTasksに元の行 | 行が復元され、削除失敗／再試行バナー |

3経路とも実JavaScriptのPromiseがSwiftの応答配送で終了し、pendingが残る現象は再現しなかった。
Swift本番コードの変更は不要。これはmacOS WebKit上の決定論的なbridge検証であり、
iOSで画面を往復・fullscreen切替した場合のWebView寿命や、本番通信の遅延・接続断までの受け入れ確認ではない。

追加検証1 test（3応答経路）成功。既存`make verify`も成功：Services 207 tests、Kernel 136 tests、
SwiftFormat／SwiftLint違反0、generic iOS Simulator app build成功。既存のMapPreview／project.ymlの未コミット差分は保持した。

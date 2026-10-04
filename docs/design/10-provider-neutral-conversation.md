# provider中立conversation契約の実装範囲

2026-10-03。todo0003の実装前棚卸。決定の正はADR0002。今回はSourcesを変更していない。

## 現在の境界

Responses function bridgeとChat Completions fallbackは既に存在する。方式選択、endpoint組み立て、
Responsesのtyped inputへの変換は実装済みだが、`LLMClient.stream`の引数は依然
`ChatCompletionRequest`であり、中立な契約への分離は未完了である。

|依存点|現状|必要な変更|
|---|---|---|
|Kernel/LLMProtocol/ChatCompletion.swift|request/message/tool定義とcallがChat wireの形|中立request/item/call/tool仕様を別ファイルへ追加し、Chat wire DTOはadapter専用に保つ|
|Services/LLM/LLMClient.swift|ChatCompletionRequestを受け、ToolCallをcompletedで返す|中立request/callへ置換。既存responseStarted/outputStarted/textDelta/completedの時刻と終端保証は維持|
|Services/LLM/OpenAICompatClient.swift|requestを直接JSON encode|中立itemからChat messagesへの写像を送信境界で行う|
|Services/LLM/OpenAIResponsesClient.swift|Chat messagesをfunction_call/outputへ再変換|中立itemから直接typed inputへ写像する|
|Services/Chat/ChatViewModelとCompletion/TurnActions|wireMessagesを保持し、request生成・性能/OTel計測もChat型|中立履歴とrequestを保持。実際の送信bodyのbytes計測をadapterで行う|
|Services/Chat/ChatRetryPlanner|user発話の序数をChatMessage.roleから求め巻き戻す|中立user itemを基準にし、tool call/outputの対応を壊さない|
|Services/Chat/RestoredWireHistoryBuilder|保存表示turnからChatMessageを復元|中立itemを復元。保存済み完全resultJSONはUI用に保持し、LLM用textを復元時も抽出|
|Services/Chat/ToolCallRunnerとPermissionGate|ToolCall.functionとToolDefinition.functionへ依存|中立call.name/argumentsとtool仕様を利用し、既存server routeと許可判定を維持|
|Services/LLM/ToolConversion.swift|MCP schema/annotationsをOpenAI ToolDefinitionへ写す|中立tool仕様へ写し、provider固有のtype/function/strictはadapterで付ける|
|Kernel/ChatModel/ChatModel.swift|永続化roleがChatMessage.Role|roleのJSON値を維持し、新roleへ移すか互換aliasを使う。保存形式変更は不要|

既存dirtyにはChatCompletion.swift、LLMClient、両client、ChatViewModel関連、stream consumer、
retry、ToolCallRunner、telemetryと各回帰テストが含まれる。ResponsesClientとCompletion/TurnActions/
RestoredWireHistoryBuilderはuntrackedだが現行実装の一部であり、削除や全ファイル置換はしない。
広い変更の前に親へ所有担当の確認を依頼済み。差分は既存内容に対する限定的変更としてレビューする。

## 最小の契約案と変更順

Kernelにprovider wireのCodingKeysを持たない`ConversationRequest`、`ConversationItem`、
`ConversationToolCall`、`ConversationTool`を追加する。itemはsystem/user/assistant本文と
tool call/outputを識別し、call ID、name、arguments JSON文字列、output textを失わない。
assistantの本文と複数callが同一ラウンドに属することをChat adapterで復元できる表現を選ぶ。
model、temperature、reasoning effortは生成設定として保持し、stream/include_usage/store/strictは
各adapterが現行の送信挙動に従って付ける。annotationsはhostの許可判定に保持し、wireへ出さない。

まず純粋な両adapter変換とfixture比較を追加し、次にLLMClient、履歴、tool実行、復元・再試行を
まとめて切り替える。公開契約だけ中立型にし内部で毎回Chat requestへ戻す段階では0003完了としない。
永続ChatSessionのキー・role値・resultJSON・カード情報は互換性を維持する。native remote MCP、
previous_response_id、JEV必須化、新catalog、SDK vendoringはこの変更に含まれない。

## 受入条件

- 同じ中立履歴から、ChatとResponsesの既存意味を保持する。本文だけ、callだけ、本文＋複数call、
  tool output、複数ラウンド、空本文、system instructionsのfixtureを両方へ写す。
- call ID/name/argumentsとoutputの対応、元MCP Tool/server route、visibility、HITL annotationsを保持。
  strict:falseを両方式で明示し、任意引数をrequired/nullへ書き換えない。
- MCP完全結果はstep/cardに保持。正常textはLLMへ縮約し、error/未知/非textは既存fullJSON fallback。
  保存会話を再開しても同じ規則を適用する。現在の復元経路はresultJSON全文を戻すため追加回帰が必要。
- responseStartedとoutputStarted、usage、tool/text完了、エラー/未完了streamの既存回帰を保持する。
  retry/edit/cancelと保存会話再開でcall/outputのペアを切断しない。
- 性能メトリクスは実際に送る各方式のbody bytesを測る。現在CompletionがChat encodeで算出する
  request bytesをResponses送信bytesと誤認しない。中立itemのOTel表示とwire bytesは別の量として記録。
- make checkとiOS全体buildを通す。外部課金推論・実機操作なしでローカルfixtureを検証できる。
  ローカルstubの低遅延は実推論3秒達成の証拠にしない。

## 0001/0002との残件

0001は正常結果の縮約と完全カード保持をローカルbenchmarkで確認済み。実Chat/Responsesのturn別
p50/p95・3秒目標は未測定。再開履歴の縮約維持と実bodyのbytes測定は0003境界変更の回帰として扱う。
0002は既存JEV小規模比較があり、実catalogでautoとの精度・追加遅延・低信頼fallback閾値は未確定。
0003のためにJEVや独自routing indexを導入する必要はない。

この棚卸は実装完了ではない。todo0003は実装開始まで@nextを維持する。

## 棚卸時のローカル再検証

`swift test --filter 'MCPResultPayloadBenchmarkTests|OpenAIResponsesClientTests'`を実行し、
5 tests / 2 suites（payloadは2入力ケース）が成功した。ログは
`/tmp/swift-provider-scope-local-20261003.log`。完全結果7185/700185 bytesに対し、
Chat送信bodyは7483/700483から304 bytes、Responsesは7468/700468から289 bytesへ縮約された。
LLM用textは38 UTF-8 bytesで、完全step/card保持とfallbackも成功。stub turnは0.827/3.151 ms。
Responsesの履歴typed item変換とstream function call/usageも通過した。外部推論・実機・OTel VMの
操作は含まない。この再検証は未実装の中立契約や保存履歴再開後の縮約を保証しない。

## 実サービスのVTODO機能probe

`LiveVTODOProbeTests`はmacOS上で実MCPの発見・AppsServerProxy・ToolCallRunner・ChatViewModel・
OpenAICompatClient・標準OTLP送信を通す。`MCPHOST_LIVE_VTODO=1`を明示した実行だけ外部接続する。
必要な環境変数はテスト冒頭に記載し、通常の`swift test`は資格情報なしでskipする。
専用リストを指定し、実行口はそのリストの`list-todos`だけを許す。要求・結果・SSE原本は
`.build/live-vtodo-probe/`（directory 0700、file 0600）へ保存する。失敗した要求も最終回答を待たず退避する。

2026-10-04の実接続ではgpt-5.6-luna/low、公開bridge、実CalDAVの22件を取得し、
全22タイトルが次LLM入力へ渡り、返却順の短い2件が最終回答へ一致することを確認した。
LLMに提示したツールは`list-todos`1件。OTLP保存先を再取得し、turn・generation2本・toolの
4 observationが全てverification環境・正常であることを照合した。保存側の時間は
turn 16.824秒、初回LLM 4.852秒、tool 1.851秒、最終LLM 10.119秒。
配送済みアプリの25ツールでの性能比較、OAuth認可UI、実機での使い心地はそれぞれ別の検証で扱う。

同じリストの1000字タイトルを含む回答要求では長時間の生成が続いた。22件の全タイトル要求は
約299秒後にid欠落のdecodeエラーとなり、元の終端error envelopeは未取得。先頭3件要求も
1000字タイトルを含み、正常deltaのままresource timeout（-1001）になった。
現在の送信型はmax_tokensを指定していない。これらは応答上限・独立deadline・長文時の失敗観測を
検討する0001の実測根拠であり、単にidをoptionalへ変えて成功扱いにはしない。
probeは独立した180秒deadlineを持つ。通常アプリの設定は変更していない。

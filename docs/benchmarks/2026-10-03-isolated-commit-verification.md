# 配送済みSwift変更の隔離commit検証

2026-10-03。元の大量dirtyを上書きせず、HEADを基にした隔離clone
`/tmp/swift-oauth-commit-20261003`へ明示file一覧だけを移して論理単位ごとに検証した。
実機への再配送、質問送信、設定/Keychain初期化、新UX/新計測は行っていない。

|単位|commit|make verify|範囲|
|---|---|---|---|
|A|5d20e929d4494489044de6d5bd0e7e38a65eaf77|Services158/Kernel131、lint155 files違反0、iOS build成功|保存clientID復元とSDK委譲transaction、503/timeout保持、clear/save競合、8 files|
|B|fb1520e|Services170/Kernel132、lint158 files違反0、iOS build成功|non-strictと未完了stream、既存Responses/Chat adapterとusage/timing前提、10 files|
|規約|576e0d4|親のd923f4dをB後へcherry-pick。親gate成功、後続Cでも検証|CLAUDE.mdの親責務1行だけ|
|C|3e1225cb2deb001ad5f7cd70bd188334a8a3a05d|Services194/Kernel136、lint168 files違反0、iOS build成功|MCP failed step/会話Error span、既存OTLPとChat分割・履歴・性能値の前提、28 files|
|D|5703d523aa23686103c5a13befe2aa2fa94ced74|Services201/Kernel136、lint177 files違反0、iOS build成功|既存provider/OTLP設定とcomposition、Keychain、推論選択と単価、14 files|
|E|本書を追加したcommit|Services201/Kernel136、lint181 files違反0、iOS build成功|既存Chat UIのmodel selector、edit/copy/feedback/regenerate、性能表示、カード/履歴telemetry、13製品files＋本書|

ログは`/tmp/swift-{oauth,b,c,d,e}-isolated-verify-20261003.log`（Aのprefixだけoauth）。
テスト数はその時点の候補treeに含めた回帰数であり、減少や省略で既存checkout全体の問題を隠した値ではない。
各単位は直前単位を含めてmake verifyを通す。new filesを自動追加せず、明示一覧をgit addへ渡した。
GitHub APIでActions workflowsとrepository webhooksはともに空。確認できる設定にpush時deploy triggerはない。
pushしたcommitは各時点でorigin/mainと一致を確認する。後続commitによりremote先端は進む。

## 読み込んだ既存差分と残境界

Bのreasoning effort/cached usage/timestampはResponses変換やstream consumerと同じ型/関数の前提。
CのChat分割、完全step保存/LLM text分離、retry/edit/restoration、performance DTO、OTLP SDKは
failed spanの実受信回帰に必要な既存実装として保存した。Dはそのclient/routerを実際のhostへ注入する
配送済みcompositionを保存する。provider中立契約への再設計や外部課金推論は追加していない。
Package.resolvedはOTel transitive追加に伴いswift-log1.14.0→1.15.1、swift-nio2.101.2→2.103.0となる。

性能0001の正常結果縮約と完全UI結果保持はlocal fixtureで検証済み。実turn p50/p95・3秒目標は未達証明。
0002の実catalog精度/追加遅延/fallback閾値、0003の中立request/item分離は未完。保存履歴再開時の
resultJSON全文再入力、ResponsesもChat形式で算出するpayload bytesは未解消である。

## -1005を既存OTelで観察できる範囲

`llm.generation.started`にはmodel、turn_id、generation_id、request_index、phaseがあり、同spanへ
input/正常output/usageを記録する。正常完了ではresponse wait/TTFT/durationも記録される。
失敗イベントは`error: String(reflecting: error)`と相関IDだけで、NSError domain/codeは独立属性ではない。
provider/API方式/baseURL、失敗時のstream段階、部分出力時刻、経過durationも属性として不足している。
span自体の開始/終了時刻は残るが、それだけで失敗したphaseを特定できない。ここでは計測を拡張していない。
synthetic TCP断のNSURLErrorDomain -1005回帰は、元実端末障害の原因特定や実trace照合の代替ではない。

端末利用の受入と実trace照合は0011。自動UI試験はユーザー指示で再開不要、準備済みfixtureは質問未送信。
MapPreview、project.ymlのpreview resource、動画、tmp-demoは今回単位へ含めない。

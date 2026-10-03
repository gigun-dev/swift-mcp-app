# MCP結果縮約のローカル基準値（2026-10-03）

todoの性能検証（0001）、JEV比較（0002）、provider中立契約（0003）を現checkoutで確認した。
既存の未コミット変更は維持し、今回の追加は検証テストと本記録だけ。Sources、端末、接続設定、
本番サービスを変更せず、外部推論・課金呼び出し・commit・push・deployを行っていない。
10/3の失敗表示・非strict・未完了stream修正と、iPhone17のinstall済み/Lockedによるlaunch未確認は
[既存の検証記録](2026-10-03-tool-failure-and-stream-verification.md)が正である。

## 0001: 実装済みと今回の検証

`ToolCallRunner.llmContent`は正常なMCP結果の`content`から非空のtext blockだけを取り出し、
次のLLM入力へ渡す。`makeFinishedSteps`は完全結果JSON、`makeCards`は完全なJSONValueを保持する。
`isError:true`、text不在、未知形状では完全JSONへfallbackする。これらの実装は今回より前の変更。

既存`ChatViewModelCardTests`に加え、`MCPResultPayloadBenchmarkTests`を追加した。実際の
ChatViewModelのtool-use loopを、2回のscripted LLMとstub MCPで実行し、二度目のrequestを捕捉。
そのrequestを現Chat encoderとResponses adapterへ渡す。比較側はtool messageだけを完全JSONへ戻す。
同じfixtureのカードと表示履歴が`content`/`structuredContent`/`isError`/`_meta`全体と一致し、
Responsesの`function_call_output`も同じ縮約textを持つことを検証した。

fixtureは`history`の反復で作る7KBと700KBの合成structured payload。LLM向けtextは
「現在の待ち時間は20分です。」の38 UTF-8 bytes。下表はモデルtoken数ではなく送信JSONのbytes。

| structured反復数 | 完全MCP結果 | LLM text | Chat 完全JSON→text | Responses 完全JSON→text |
| ---: | ---: | ---: | ---: | ---: |
| 1,000 | 7,185 | 38 | 7,483→304 | 7,468→289 |
| 100,000 | 700,185 | 38 | 700,483→304 | 700,468→289 |

7KB fixtureの送信bodyはChatで95.9%、Responsesで96.1%減少。700KB fixtureでは両方99.95%以上減少。
このrequestはtools定義なしの最小fixtureなので、実カタログ/schema/会話履歴付きrequest全体の削減率ではない。
エラー結果とtext不在結果について、完全JSON fallbackを別テストで確認した。

stub turnは初回実行で1.091ms / 3.488ms、既存性能テストを含む再実行で0.730ms / 3.231ms、
lint修正後の最終実行で0.821ms / 3.213ms。
これはメモリ内LLM/MCP、debug buildのローカルloop時間であり、ネットワーク、モデル推論、
WKWebView描画、iPhone実機時間を含まない。標本3回でp50/p95を算出せず、3秒目標の達成とは扱わない。

再現:

```sh
swift test --filter 'MCPResultPayloadBenchmarkTests|ChatViewModelTests/MCPのtext|performanceAccumulator|completionConsumerRecords|requestPayloadMetrics'
swiftformat Tests/ServicesTests/MCPResultPayloadBenchmarkTests.swift --lint --config .swiftformat --cache ignore
swiftlint lint --config .swiftlint.yml --strict --no-cache Tests/ServicesTests/MCPResultPayloadBenchmarkTests.swift
```

9 tests成功。新規ファイルのSwiftFormat/SwiftLint違反0。既存性能テストではturn最初のmodel出力と
request単位TTFTの分離、複数requestの集計、本文を含まないpayload診断を確認した。
今回make check/make app/実機受入は実施していない。

未完は同モデル・同履歴・同実MCP結果でのChat/Responses比較、初回判断/MCP/最終回答の各時間、
実token数、全turn時間のp50/p95と3秒目標の判定。縮約のbytes減少からlatency改善を推定しない。

## 0002: JEVの位置付けと残作業

[9/21の探索記録](jev-routing-2026-09-21.md)には3候補18/18、30候補の期待値一致14/16、
暫定gate、候補数別の時間/token、合成192/360 tools比較がある。
同記録には小標本・合成カタログ・分離測定を合算した値という限界も明示されている。
今回のSources検索でJEV clientや`ToolRoutingPort`の実装は確認できず、製品routerは導入済みと扱わない。

未完は実MCPカタログのラベル付き入力でautoとの一体比較、誤自動実行率、fallback率、
confidence/選択確率/marginの閾値、coldを含むp50/p95、履歴条件別の精度、費用。
ADR0002どおり、標準metadataを使う任意adapterの実験であり、中核契約へ独自taxonomyを追加しない。
今回は外部JEV推論を再実行していない。

## 0003: API adapterと中核契約を区別

`LLMAPIStyle.defaultStyle`は公式OpenAIをResponses、互換URLをChat Completionsにする。
`OpenAIResponsesClient.responsesBody`はassistant tool callとtool outputをtyped itemへ変換している。
このAPI方式切替・adapterは既存実装済み。

一方、`LLMClient.stream`の引数は今も`ChatCompletionRequest`であり、ChatViewModelのrequest生成と
Responses adapterもこの型に依存する。provider中立なconversation item/tool callの中核分離は未完。
ADR0003の標準OTLP境界は観測の決定であり、LLM会話契約の中立化が完了した根拠にはならない。
今回は設計・Sourcesを変更していない。

## ユーザー受入の短い手順

端末をunlockした後の起動確認はdeliveryタスク0008の残作業。性能計測と-1005原因特定を混同しない。
起動後、同じ接続・モデル・read-onlyの同じ質問を新規chatでChat/Responsesそれぞれ実行する。
期待結果は正常回答と同じMCP Appsカード、詳細履歴には完全結果、LLM再入力は正常textのみ。
比較は表示されるfirst responseだけで終えず、request phase・MCP duration・最終completion・payload bytesと
token usageを同じturnへ相関し、同条件で複数回記録する。書込質問は不要。

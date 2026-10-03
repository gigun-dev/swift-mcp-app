# JEV 事前ルーティング実測（2026-09-21）

## 目的

MCP の全ツール定義を最初の LLM 呼び出しへ渡して `auto` 選択させる前に、軽量な分類器で
`none` または呼び出すツールを絞れるかを確認した。JEV は Cloudflare Workers AI の
`typesafe/jev` を Unified Billing 経由で呼び出した。

## 汎用ツールルーティング

候補を `none` / `get_current_time` / `attraction_wait` とし、次の6入力を各3回評価した。

- `hello` → `none`
- `今何時？` → `get_current_time`
- `明日は何曜日？` → `get_current_time`
- `スプラッシュマウンテン` → `attraction_wait`
- `ソアリンの待ち時間` → `attraction_wait`
- `文章を短くして` → `none`

結果は **18/18 正解**。ウォーム時は概ね **278〜390 ms**、入力 **395〜405 tokens**、
出力 **43〜46 tokens** だった。初回だけ約 **2.1 s** のコールドスタートがあった。

この時点の入力はユーザー発話と3候補の名前・説明だけで、JSON Schema全体は渡していない。JEVは
`none` / `get_current_time` / `attraction_wait` のいずれかを返すだけで、引数生成やツール実行はしない。

既存の簡易比較では、Responses API で `tool_choice:auto` から特定ツール指定へ変えると、
ツール選択を含む最初の LLM 呼び出しを約 **1.4 s** 短縮できた。JEV のウォーム時追加時間を
差し引くと、単純ケースでは約 **1.0〜1.1 s** の短縮余地がある。ただしツール実行後の
最終回答 LLM 呼び出しは残る。

## MCPカタログを直接渡すルーター

30個の現実的なMCPツール名・説明に `none` と `multiple_tools` を含め、16入力を各2回評価した。
両試行とも期待値に一致したケースは **14/16**、選択自体は **16/16で安定**した。

- `今何時？`、天気、TDR待ち時間、営業時間、予定参照、予定作成、場所検索、メール送信、メモ作成、
  相場取得は期待したツールへルーティングした。
- `週末の予定と天気` は `multiple_tools` を選び、単一ツールへ誤確定しなかった。
- `この文章をもっと短くして` は `documents__summarize`、情報不足の `調べて` は `web__search` を選んだ。
  どちらもツール不要または要確認とした期待値には不一致だった。

誤りのconfidenceは0.66〜0.75だった。一方、明確なread-onlyツールは概ね0.90〜1.00だった。
選択確率とconfidenceの小さい方へ暫定gateを置いた場合、この32試行では次の結果になった。

| gate | 自動処理 | 自動処理の正解率 | fallback |
| ---: | ---: | ---: | ---: |
| 0.70 | 28/32 | 92.9% | 4/32 |
| 0.75 | 26/32 | 96.2% | 6/32 |
| 0.80 | 22/32 | 100% | 10/32 |
| 0.85 | 22/32 | 100% | 10/32 |

標本が小さいため閾値は確定しない。特に書き込みツールはルーティング精度とは別に既存の承認gateを通す。

### 候補数と速度

同じ明確な待ち時間質問へ候補を増やし、各3回の中央値を比較した。

| Choice候補数 | latency中央値 | input tokens | output tokens |
| ---: | ---: | ---: | ---: |
| 3 | 574 ms | 427 | 51 |
| 10 | 517 ms | 593 | 121 |
| 30 | 439 ms | 991 | 303 |
| 71 | 750 ms | 2,430 | 840 |
| 100 | 740 ms | 3,449 | 1,221 |
| 255 | 646 ms | 9,028 | 3,310 |

速度は候補数に対して単調増加せず、今回の範囲では概ね同じオーダーだった。一方、全候補の確率分布を
返すためtoken量は大きく増える。多数候補を毎回そのまま渡せることと、常に渡すべきことは別である。

曖昧入力では候補数によって分布も変わった。`この文章をもっと短くして` は3候補でsummarize、30候補で
`none`、100候補では試行間で分かれた。candidate setを会話ごとに不用意に変えると、同じconfidence閾値でも
挙動が変わりうる。

Choiceに加え「外部ツールが必要か」「副作用があるか」のNoulを同一リクエストへ追加した比較では、
中央値388msから530ms、input 962→1,004、output 299→336 tokensだった。質問を直列に分けるより、
必要な補助判定をspeculative fan-outで同時取得する余地がある。

## TypeSafeの公開パターンとの整合

TypeSafe公式ドキュメントではroutingを主要用途とし、Choiceへ全候補と`none of the above`を渡し、
確率分布とconfidenceをコード側で使う。Choiceは最大255候補で、複数の質問は1回にまとめて並列評価する。
confidenceは分布の集中度から作られる便宜的な値で、用途固有の判定には確率分布を直接使ってよい。

公式playgroundのJEV tool routerは、ユーザー要求・現在ノード・許可済み候補一覧を入力し、
`needs_clarification`を常に候補へ加える。選択確率とconfidenceの両方に0.85 gateを置き、失敗・曖昧・
未知ノードはclarificationへ戻す。JEVは引数やアクションを生成せず、候補集合、blocked policy、書き込み承認を
決定論コードで再検証する。この境界は本アプリの`ToolRoutingPort`と整合する。

参考:

- [TypeSafe use-case map](https://docs.typesafe.ai/concepts/use-case-map.md)
- [Choice](https://docs.typesafe.ai/primitives/choice.md)
- [Confidence](https://docs.typesafe.ai/confidence.md)
- [Confidence-gated routing](https://docs.typesafe.ai/patterns/confidence-routing.md)
- [TypeSafeAI playground tool router](https://github.com/TypeSafeAI/typesafe-playground/blob/main/docs/tool-router.md)

## 一般的なMCPレイテンシとの比較

MCP tool callingに単一の業界標準時間はない。モデル、接続方式、ツール数、schema量、ツール結果量、
最終回答長、反復回数で桁が変わる。ProMCPは20 servers / 169 toolsを6段階に分解し、単純なMCP-Benchで
custom local clientが1.28±0.52秒と3.90±1.43秒、custom cloud clientが22.76±4.21秒、off-the-shelf
clientが94.86±18.11秒だった。絶対値は構成依存だが、custom clientではplanning/schema injectionが
latencyの60〜67%、off-the-shelfでは最終回答が85%以上を占め、tool execution自体は小さかった。

したがって本アプリの現行2.81秒は単純tool-callとして異常に遅い値ではない。ただし内訳が初回判断1.28秒、
MCP 0.11秒、最終回答1.42秒なので、JEVで最初のplanning/schema入力を削る余地は大きい。

参考: [ProMCP (ACL Findings 2026)](https://aclanthology.org/2026.findings-acl.1967/)

## 施設名解決

TDR の71施設すべてと `none` を一度に JEV の choice とした場合、入力は約
**4.9k tokens**、出力は約 **2.7k tokens** まで増えた。既知の略称や表記揺れは選べたが、
`カルーセル` を2施設の曖昧入力として保持せずランド側へ確定した。全施設直選択は、通信量と
誤確定の両面で通常経路には採用しない。

静的マスタの完全一致・alias・部分一致を先に使い、未解決時だけ n-gram の上位候補を
JEV に渡す方式も計測した。choice には候補に加えて `ambiguous` と `none` を含めた。

| 入力 | 候補数 | 判定 | 逐次実行時間 | input / output |
| --- | ---: | --- | ---: | ---: |
| スプラシュマウンテン | 2 | スプラッシュ・マウンテン | 368 ms | 429 / 53 |
| フローズン物語 | 1 | フローズンジャーニー | 333 ms | 399 / 44 |
| ジェットコースター | 2 | ambiguous | 292 ms | 442 / 54 |
| カルーセル | 2 | ambiguous | 315 ms | 422 / 52 |

候補を絞ることで表記揺れを拾い、一般名は確認へ戻せた。TDR 固有の通常経路は次とする。

1. 完全一致・alias・安全な部分一致は決定論で解決する。
2. 複数 exact/partial 候補は JEV を呼ばず、曖昧候補としてユーザーへ返す。
3. 「船に乗って冒険する」のように複数施設へ意味的に当てはまる入力は、候補提示か確認へ戻す。
4. 表記揺れを決定論で拾えず意味的な補助が必要な場合だけ、少数候補へ JEV を使える余地を残す。

通常の施設選択では JEV を通さない。JEV の主用途は次節の汎用 MCP ルーティングとする。

## gpt-5.4 / Responses API 比較

OpenAI 公式 API の `gpt-5.4`、reasoning effort `none`、同じ TDR MCP
（`park_waits` / `park_hours` / `attraction_wait`）で小標本を比較した。時間はネットワークを含む
クライアント観測値であり、p50/p95 ではない。

| 経路 | 入力 | 全体 | 内訳・観察 |
| --- | --- | ---: | --- |
| Responses + ローカル function tools（現行相当） | 待ち時間 | **2.81 s** | 初回判断 1.28 s + MCP 0.11 s + 最終回答 1.42 s |
| Responses native MCP（初回） | 待ち時間 | **4.92〜6.78 s** | `mcp_list_tools` の後に `mcp_call`。1 HTTP request内だがモデル処理は複数段階 |
| Responses native MCP（`previous_response_id` で一覧再利用） | 続けて別施設 | **3.39 s** | `mcp_list_tools` は再実行されなかった |
| Responses native MCP | `こんにちは` | **2.18 s** | ツール不要でも初回は `mcp_list_tools` が発生 |
| Responses `tool_search` + deferred tools | 待ち時間 | **4.31 s** | 3ツールでは探索段階の追加コストが上回った |
| JEV route + ローカル MCP + Responses最終回答 | 待ち時間 | **推定1.44〜1.97 s** | MCP+最終回答の実測1.15〜1.58 sに、別計測のJEV 0.29〜0.39 sを加算 |

native MCP は remote MCP の一覧取得、呼び出し、出力受け渡しを Responses API に委ねられる点では
構造が明快だった。一方、今回の3ツールでは `mcp_list_tools` とモデル側の判断が支配的で、現行の
function tools より遅かった。native対応であること自体は低遅延を保証しない。

`tool_search` の deferred loading も小さいカタログには使わない。MCP が多数接続され、全スキーマを
毎回入力へ載せるコストが大きい場合に改めて比較する。

## 採用するルーティング境界

アプリは provider や TDR に依存しない `ToolRoutingPort` を持ち、次の結果だけを受け取る。

- `none`: ツールなしで LLM を1回呼ぶ。
- `tool(server, name)`: 許可された候補だけをローカル実行し、結果から最終回答を1回生成する。
- `fallback`: 既存の LLM `auto` へ戻す。

任意のJEV adapterを有効にした場合だけ、次の4段階を通す。

1. deterministic ruleでblocked toolを除外し、許可済み候補だけを作る。
2. MCP `tools/list`のname、title、descriptionをそのままChoice候補へ変換する。
3. JEV Choiceへ`none` / `multiple_tools` / `needs_clarification` / 全候補を渡す。
4. 選択確率・confidence・上位2候補margin・tool riskから、直接実行、上位候補だけLLMへ提示、確認、
   または既存`auto` fallbackをコードで決める。

`none`は正常なルーティング結果であり、fallbackではない。`multiple_tools`もmulti-step plannerへ渡す正常結果とする。
fallbackはJEV障害、低信頼、候補外、または引数生成に追加推論が必要な場合へ限定する。

### 標準経路とJEV実験の境界

JEVを使わなくてもMCP hostとして正しく動く経路を標準とする。hostはMCP `tools/list`をfunction toolsへ写像し、
modelのfunction callをMCP `tools/call`として実行する。wire APIはResponsesを優先し、未対応providerだけ
Chat Completionsへ落とす。これは追加のcatalog契約を必要としない。

JEVは任意のperformance adapterとしてだけ比較する。使う場合はMCP `tools/list`が返したname、title、descriptionを
直接Choice候補にし、host独自index、capability taxonomy、手動clusterは作らない。255件を超える場合のchunkingは
JEV固有の制約として明示し、その複雑さが効果に見合わなければ採用しない。

現在の`OpenAIResponsesClient`はResponses endpointを使うが、入力契約は`ChatCompletionRequest`である。
次の実装優先度はJEV routerではなく、このwire型依存をprovider中立なconversation item / tool call契約へ外すこと。
Responses adapterはtyped item、Chat Completions adapterはmessagesへそれぞれ変換する。

### 次の評価マトリクス

単純な正解率だけでなく、次を同じラベル付き入力集合で比較する。

- 標準のResponses function bridgeを、Chat Completions function bridge、JEV全候補Choice、
  OpenAI native MCP / `tool_search`と比較する。
- tool不要、単一read-only、単一write、複数tool、曖昧、候補外、prompt injectionを分ける。
- top-1 accuracy、top-k recall、誤自動実行率、fallback率、coverageごとのprecision、確率校正、
  p50/p95、input/output tokens、費用を記録する。
- confidence、選択確率、top-1/top-2 margin、正規化entropyを別々に比較し、read-onlyとwriteでgateを分ける。
- 会話履歴を含む場合は最新発話だけ、短い要約、全履歴の3条件を比較する。

方式の採否は平均速度だけで決めず、実カタログでの誤自動実行率、p95、token量、MCP Apps・許可・観測の
互換性を合わせて決める。JEVは比較対象であり、製品の正しさを依存させない。

### 全ツール1段とMCP→tool 2段の比較

8個のMCP serverに各24 tools、合計192 toolsを持つ合成カタログで、同じ予定作成入力を各5回評価した。
両方式とも全試行で`calendar__create_event`を選んだ。

| 方式 | latency中央値 | input tokens | output tokens | 逐次JEV回数 |
| --- | ---: | ---: | ---: | ---: |
| 全192 toolsを1 Choice | **673 ms** | 6,573 | 2,307 | 1 |
| MCP 8択 → 選択MCP内24 tools | 960 ms | **1,635** | **431** | 2 |

255を超える360 toolsでは、全候補を180件ずつ2 Choiceへ分割して同じリクエストで並列評価し、各chunkの
上位3件を2回目のChoiceでrerankする方式と、MCP 12択→30 toolsを比較した。各3回とも正しいtoolを選んだ。

| 方式 | latency中央値 | input tokens | output tokens |
| --- | ---: | ---: | ---: |
| 180件×2 parallel chunks → shortlist rerank | 1,042 ms | 12,456 | 4,441 |
| MCP 12択 → 選択MCP内30 tools | **1,012 ms** | **1,877** | **531** |

これは合成カタログ・単一入力の探索値であり、精度比較ではない。得られた判断は次のとおり。

- 255以下で説明が短い場合、全ツール1段がwall-clock latencyでは有利。
- 2段は約1回分のネットワーク・推論時間を足すが、token量を大幅に減らす。
- 255超ではparallel chunk→rerankとMCP→toolはいずれも2段になり、今回の速度は同程度だった。
- MCPという物理的な所属がユーザー意図と一致するなら、MCP→toolは最もtoken効率がよい。
- 複数MCPに似たtoolがある、1つのMCPが多領域を持つ、複数MCPが必要、という入力では最初のMCP誤選択が
  回復不能になる。top-1を確定せず、上位K個のMCP配下をparallel Choiceで評価するbeam方式が安全。
- 物理MCP境界や推定capability clusterは意味分類に使わない。
- parallel chunksと全候補Choiceは比較baselineに限定し、候補数で実行方式を切り替えない。

TypeSafeのskill suggestion cookbookも182 skillsを1つのwide Choiceでrankし、上位3件だけ詳細情報付きで
rerankする。さらに数倍の候補ではchunkごとにrankしてwinnerをshortlistへ集める方針を示す。階層分類では
greedy top-1が4例中2例、beam K=3が4例中4例で、早い段階の誤選択を複数経路保持で回復した。

参考:

- [Skill suggestion cookbook](https://docs.typesafe.ai/cookbooks/skill_suggestion.md)
- [Hierarchical classification cookbook](https://docs.typesafe.ai/cookbooks/hierarchical_classification.md)
- [JEV実測記事](https://zenn.dev/mizchi/articles/jev-is-gpu-for-llms)

JEV はこの port の高速 adapter 候補とする。信頼度が十分で、read-onlyかつ既存の許可ポリシーを満たす
場合だけ直接実行する。書き込み系は従来どおり確認ゲートを通し、ルーターが許可を迂回しない。
OpenAI native MCP は実験可能な別 adapter として残すが、今回の計測だけでは既定にしない。

## 実装境界

Swift アプリに Cloudflare API token は埋め込まない。汎用ホスト側には
`ToolRoutingPort` 相当の中立な境界を置き、ツール名・説明・ユーザー入力を受けて
`none` / tool / fallback を返す。JEV 固有の認証とリクエストは、認証・rate limit を持つ薄い
Worker adapter に置く。TDR の施設名解決は MCP サーバーのドメイン処理として維持し、汎用クライアントへ
71施設の知識を入れない。

次の検証は実MCPカタログを使った精度評価、低信頼・margin 閾値の決定、コールドスタートを含む
p50/p95、および JEV → MCP → 最終回答を一体で計測するプロトタイプである。

# OpenAI公式ではResponses APIを既定にし互換接続ではChat Completionsを維持する

Date: 2026-09-20

OpenAI公式APIではResponses APIを既定にする。`api.openai.com` 以外のOpenAI互換接続は、互換性を優先してChat Completionsを初期値にする。自動判定をUIや保存値として持たず、接続ごとに「Responses」または「Chat Completions」を明示保存して比較できるようにする。接続URLはAPI方式に依存しない `/v1` base URLまでとし、クライアントが選択された方式に応じて末尾を組み立てる。

Responses APIはメッセージ、function call、function call outputを型付きitemとして扱うため、MCPツールを含む複数ラウンドの会話をAPI本来の表現で送れる。一方、OpenAI互換プロバイダにはResponses APIを実装していないものが多く、URLだけから対応可否を安全に判定できない。プリセット選択時だけ妥当な初期値を与え、その後はユーザーが選んだ方式を使う。

現在は会話履歴を端末側で保持し、Responses APIにも各リクエストで必要な履歴を送る。`previous_response_id` とnative remote MCPは将来の最適化とし、今回の切り替えに含めない。

2026-09-21追記: `gpt-5.4` とTDRの3ツールでnative remote MCPを実測した。初回は
`mcp_list_tools` を含め4.92〜6.78秒、`previous_response_id` で一覧を再利用した次ターンも3.39秒で、
ローカルfunction toolsの2.81秒より遅かった。native remote MCPはprovider-managedな実行方式として
実験可能に保つが、低遅延化の既定にはしない。

同日再整理: JEVやhost独自の検索indexを標準経路の前段には置かない。MCPは`tools/list`と`tools/call`を
標準化する一方、候補検索indexや能力taxonomyは標準化していない。OpenAI Responsesはfunction callと
native remote MCPを持ち、Chat Completionsはfunction callを持つ。このため中核をChat Completions wire型から
provider中立な会話item・tool callへ分離し、次のadapterで表現する。

- Responses function bridge: hostがMCPを列挙・実行し、Responsesの`function_call` /
  `function_call_output`へ写像する。MCP Apps表示、許可、OTelをhostに残す既定経路。
- Chat Completions function bridge: Responses非対応の互換provider向けfallback。
- Responses native MCP: providerへremote MCP実行を委譲できる接続だけのopt-in実験経路。

function bridgeで変換するのはmodel-facingなname、description、input schemaとtool call表現だけである。
hostは元のMCP Tool、`_meta.ui.resourceUri`、server routeを保持し、modelのfunction callを元の
MCP `tools/call`へ戻す。返却された`CallToolResult`は`content`、`structuredContent`、`isError`、`_meta`を
欠落させず、modelへ渡すtextとMCP Appへ渡す完全結果へ分ける。この不変条件を満たす限り、function callへの
変換でMCP Apps表示は失われない。

native MCPではproviderがtool実行を所有するため、hostが完全な`CallToolResult`とUI resource metadataを
受け取れないproviderではMCP Appsカード、host側HITL、詳細OTelを同等に実装できない。これらを必要とする
チャットではResponses function bridgeを既定とする。

JEVは`tools/list`の標準metadataを直接Choiceへ渡す任意の性能adapterとして比較を続けるが、正しさや互換性に
必要な中核機能にはしない。独自index、独自taxonomy、手動clusterは導入しない。

Rejected: すべての接続をResponses APIへ移行すると、Chat Completionsだけを実装する互換プロバイダが利用不能になる。

Rejected: すべての接続をChat Completionsのままにすると、公式OpenAIでResponses APIのtyped item、将来のremote MCP、会話状態最適化を試せない。

Rejected: JEV用のhost独自indexやcapability clusterを必須化すると、MCP/OpenAI互換の外側に独自の
catalog契約が増え、別projectや別hostへ持ち込みにくい。

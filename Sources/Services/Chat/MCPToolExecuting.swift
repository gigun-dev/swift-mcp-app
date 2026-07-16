// tool-use ループ(ChatViewModel・T3)が「MCP ツールを1本実行する」だけを頼むための最小抽象。
//
// なぜ専用プロトコルを切るか(AppsServerProxy を直に握らない理由):
//  1. **テスト容易性** — ループの検証(ChatViewModelTests)はネットワーク・swift-sdk の
//     `Client`・OAuth 一切なしで回したい。実行口を1メソッドのプロトコルにしておけば、
//     テストは「呼ばれた name/arguments を記録し、決め打ちの JSONValue を返す」スタブに
//     差し替えるだけで済む(設計 §3 のループ検証を live なしで通す)。
//  2. **中立性(CLAUDE.md ビジョン2)** — ループは「ツールを名前と引数で叩くと JSON が返る」
//     以上のことを知らなくてよい。AppsServerProxy が持つ発見(ui:// 解決)や HTML プリフェッチは
//     カード描画(T5)の関心事で、テキスト往復の T3 には不要。関心を最小面積に絞る。
//
// シグネチャは AppsServerProxy.callTool(name:arguments:) と**完全一致**させてある
// (下の extension が本体を1行も書かずに conformance できるように)。arguments を JSONValue?
// にしているのは、ループ側が受け取る tool_call の arguments(OpenAI では JSON 文字列)を
// JSONValue に復元してから渡すため(型付き DTO にしない = 中立・素通しの JSONValue 方針)。
import Foundation
import Kernel

/// MCP ツールを1本実行する口。実体は AppsServerProxy(実接続)、テストではスタブ。
///
/// Sendable 制約: ChatViewModel が複数 tool_call を TaskGroup で**並行実行**する(設計 §3
/// 「複数 tool_call は並行実行」)ため、実行口は並行安全でなければならない。AppsServerProxy は
/// actor なので自明に満たし、テストスタブも actor/不変値で満たす。
public protocol MCPToolExecuting: Sendable {
    /// ツールを名前+引数で呼び、結果を JSONValue(ロスレス)で返す。
    ///
    /// **不変条件(設計 03 §1 決定(a))**: `arguments: nil` は呼び出し側(ChatViewModel)が
    /// 「引数なし」と解釈した意図を表すが、実装(AppsServerProxy.mcpArguments)はこれを
    /// **ワイヤ上では `{}`(空 object)として送る**。フィールド自体の省略はしない
    /// (TS SDK 製サーバーの zod object 検証が `undefined` を拒むため — 一次資料は
    /// docs/design/03-tool-io-and-card-freshness.md §1)。この protocol のシグネチャに
    /// `JSONValue?` を残しているのは「呼び出し側が引数なしを表明する自然な形」を保つためで、
    /// nil→`{}` の正規化は実装側の責務として閉じ込める(呼び出し側は気にしなくてよい)。
    func callTool(name: String, arguments: JSONValue?) async throws -> JSONValue
}

// AppsServerProxy(P2)は既にこのシグネチャの callTool を持つ(actor・ロスレス JSONValue を返す・
// AppsServerProxy.swift:145)。メソッドを1つも足さずに宣言だけで適合する。actor が async 要求を
// 持つプロトコルに適合するのは Swift 並行モデル上正当(呼び出しは await 境界を跨ぐ)。
extension AppsServerProxy: MCPToolExecuting {}

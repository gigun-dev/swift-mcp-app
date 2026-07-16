// MCP tools/list(swift-sdk の `[Tool]`)→ OpenAI 互換 `[ToolDefinition]` への変換
// (設計 §1「MCP↔LLM 変換は Services/LLM」・§7「visibility 除外は変換直前」)。
//
// なぜ Services に置くのか(Kernel でなく): この変換は swift-sdk の型 `MCP.Tool` /
// `MCP.Value` に触れる。Kernel は swift-sdk 非依存が絶対制約(CLAUDE.md)なので、
// swift-sdk 型に触れてよい最も内側の層 = Services が変換の置き場になる。visibility の
// 判定「ロジック」自体は Kernel の純関数(isModelVisible)に委ね、ここは MCP.Value →
// JSONValue の橋渡しと除外の適用だけを担う(§7「実装点」)。
import Foundation
import MCP
import Kernel

/// MCP のツール一覧を、LLM に渡す OpenAI ToolDefinition 配列へ変換する。
///
/// **変換の直前に visibility 除外を適用する**(apps.mdx:400 MUST・設計 §7):
/// 各 Tool の `_meta.ui`(あれば)を JSONValue にして `isModelVisible` に渡し、
/// false(= visibility に "model" を含まない。例 visibility:["app"])のツールを落とす。
/// `_meta` や `ui` が無いツールは uiMeta=nil → 既定 `["model","app"]` 扱いで残る(§7)。
///
/// - Parameter tools: `MCPConnectionResult.tools`(P1)や `client.listTools()` の結果。
/// - Returns: LLM の tools フィールドに載せる ToolDefinition 配列。
/// - Throws: `_meta` や inputSchema の JSONValue 変換(JSON 経由)に失敗した場合。
///   実データでは起きないが、握りつぶさず投げて異常に気づけるようにする。
public func toolDefinitions(from tools: [Tool]) throws -> [ToolDefinition] {
    try tools.compactMap { tool -> ToolDefinition? in
        // 1) visibility 除外(変換の前に判定する。落とすツールは JSONValue 変換も省ける)。
        let uiMeta = try uiMeta(from: tool)
        guard isModelVisible(uiMeta: uiMeta) else {
            // "model" を含まない(= モデルに見せてはいけない)ツールは LLM 一覧から除外。
            // caldav では refresh-todos / refresh-events が該当(server.ts:1564/995)。
            return nil
        }

        // 2) inputSchema(MCP.Value)→ JSONValue(JSON Schema)。MCP.Value は Encodable なので
        //    JSONValue(encoding:) で JSON を1往復させて写す(AppsServerProxy と同じ流儀)。
        //    JSON Schema と MCP の inputSchema はほぼ同型(object/properties/required)なので
        //    構造変換は不要、素通しでよい。
        let parameters = try JSONValue(encoding: tool.inputSchema)

        return ToolDefinition(function: .init(
            name: tool.name,
            description: tool.description,
            parameters: parameters
        ))
    }
}

/// Tool の `_meta.ui`(JSONValue)を取り出す。`_meta` 自体や `ui` キーが無ければ nil。
///
/// AppsServerProxy.fetchAppHTML と同じ書き方: `_meta`(MCP.Metadata)の `fields`
/// (`[String: Value]`)を JSONValue へ丸ごと写してから `["ui"]` を引く。こうすると
/// Kernel の純関数(isModelVisible/isAppCallable)には JSONValue だけが渡り、Kernel は
/// swift-sdk の MCP.Value に一切触れない(§7 の依存分離)。
///
/// internal 公開: app 発 tools/call 拒否(AppsServerProxy・§7 の 401 MUST)でも
/// 同じ「Tool → uiMeta(JSONValue)」抽出が要るため、Services 内で共有する。
func uiMeta(from tool: Tool) throws -> JSONValue? {
    guard let meta = tool._meta else { return nil }
    return try JSONValue(encoding: meta.fields)["ui"]
}

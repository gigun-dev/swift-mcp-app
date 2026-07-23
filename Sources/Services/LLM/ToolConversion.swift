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
            parameters: parameters,
            // R4: annotations(untrusted hint)を Kernel の許可ゲート判定へ運ぶ。従来はここで落ちていた。
            annotations: kernelAnnotations(from: tool.annotations)
        ))
    }
}

/// swift-sdk の `Tool.Annotations`(Tools.swift:35)を Kernel の `ToolAnnotations` へ写す。
///
/// なぜ Services で写すか(Kernel でなく): swift-sdk の型に触れる変換なので、他の MCP→Kernel 変換
/// (uiMeta 抽出等)と同じく最も内側で swift-sdk に触れてよい層 = Services に置く。全フィールドが
/// 空(サーバーが annotations を一切付けていない)なら nil を返す——「未申告」を Kernel 側でも
/// nil として表現し、性悪説の既定(確認必須)へ自然に倒す(ToolPermissionPolicy 参照)。
func kernelAnnotations(from annotations: Tool.Annotations) -> ToolAnnotations? {
    if annotations.isEmpty { return nil }
    return ToolAnnotations(
        title: annotations.title,
        readOnlyHint: annotations.readOnlyHint,
        destructiveHint: annotations.destructiveHint,
        idempotentHint: annotations.idempotentHint,
        openWorldHint: annotations.openWorldHint
    )
}

/// MCP のツール一覧を、slug で名前空間化しつつ LLM の ToolDefinition 配列へ変換する(M2)。
///
/// `toolDefinitions(from:)` と同じく visibility 除外を適用したうえで、ツール名を `slug__tool` に前置し、
/// description の末尾に「(サーバー名)」を添える(**LLM が「どのサーバーのツールか」を選びやすくする**
/// 補助・タスク指示 §3 の任意項目。1つの LLM に複数サーバーのツールを混ぜると、素の名前だけでは
/// モデルがどのサーバー向けか判断しづらい場面があるため、出自を description で明示する)。
///
/// - Parameters:
///   - tools: そのサーバーの tools/list 結果。
///   - slug: そのサーバーの名前空間 slug(ToolNamespacing.slug で決定的に生成済み)。
///   - serverName: description に添えるサーバー表示名(ユーザーが付けた name)。
/// - Returns: 前置名・出自注記済みの ToolDefinition 配列(visibility 除外後)。
public func prefixedToolDefinitions(from tools: [Tool], slug: String, serverName: String) throws -> [ToolDefinition] {
    try tools.compactMap { tool -> ToolDefinition? in
        let uiMeta = try uiMeta(from: tool)
        guard isModelVisible(uiMeta: uiMeta) else { return nil }
        let parameters = try JSONValue(encoding: tool.inputSchema)
        // description に出自を添える(既存説明があれば後ろに、無ければ注記だけ)。
        let annotated: String
        if let base = tool.description, !base.isEmpty {
            annotated = "\(base)（サーバー: \(serverName)）"
        } else {
            annotated = "（サーバー: \(serverName)）"
        }
        return ToolDefinition(function: .init(
            name: ToolNamespacing.prefixed(slug: slug, tool: tool.name),
            description: annotated,
            parameters: parameters,
            // R4: 前置名変換でも annotations を保持する(名前空間化は許可ゲートの判定材料を変えない)。
            annotations: kernelAnnotations(from: tool.annotations)
        ))
    }
}

/// そのツールが LLM のツール一覧に載る(= visibility に "model" を含む)かを返す(設定画面の
/// tools/list ビューアで「app 専用」バッジを出すために使う・追加スコープ)。`_meta.ui` の抽出込み。
public func isToolModelVisible(_ tool: Tool) throws -> Bool {
    try isModelVisible(uiMeta: uiMeta(from: tool))
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

// 複数サーバーのツールを1つの LLM から叩くための実行口(M2・複数サーバー同時接続)。
//
// tool-use ループ(ChatViewModel)は MCPToolExecuting を1つだけ握る前提(単一実行口)。M2 では
// 複数の AppsServerProxy(サーバーごと)へ、LLM が返した前置ツール名(`slug__tool`)に応じて
// **委譲先を振り分ける**必要がある。そこで MCPToolExecuting を実装する「合成 executor」を1枚かませ、
// ループ側は従来どおり単一の口を見るだけにする(ループは名前空間化を知らない = 中立・CLAUDE.md ビジョン2)。
//
// 名前の変換ロジック(slug 生成・前置・逆引き)は Kernel の ToolNamespacing(純関数・テスト済み)に
// 隔離し、ここは「逆引き結果の slug で proxy を選び、元ツール名で callTool する」ルーティングだけを担う。
import Foundation
import Kernel

/// slug → その サーバーの実行口(AppsServerProxy)の対応表を持ち、前置ツール名を振り分ける executor。
///
/// struct(値型)にした理由: 保持するのは `[String: any MCPToolExecuting]`(proxy は actor = 参照型
/// なので dict のコピーは軽い)だけで、可変状態を持たない。ChatViewModel が build 時に1個作って
/// 握るだけ(接続の増減は「次の新規チャットで新しい MultiServerToolExecutor を組む」方針なので、
/// この executor 自身は不変でよい — 途中差し替えをしない設計・タスク指示 §3)。
public struct MultiServerToolExecutor: MCPToolExecuting {
    /// slug → 実行口。テスト差し替えのため `any MCPToolExecuting`(本番は AppsServerProxy)。
    private let executors: [String: any MCPToolExecuting]
    /// 短縮済み wire 名を元の `(slug, tool)` へ戻す表。短い従来名も含めてよい。
    private let routes: [String: ToolRoute]
    /// 同一 wire 名が異なる route を指した場合は、辞書の後勝ちにせず実行時に明示拒否する。
    private let ambiguousWireNames: Set<String>

    public init(executors: [String: any MCPToolExecuting], routes: [ToolRoute] = []) {
        self.executors = executors
        var indexed: [String: ToolRoute] = [:]
        var ambiguous = Set<String>()
        for route in routes {
            if let existing = indexed[route.wireName], existing != route {
                indexed.removeValue(forKey: route.wireName)
                ambiguous.insert(route.wireName)
            } else if !ambiguous.contains(route.wireName) {
                indexed[route.wireName] = route
            }
        }
        self.routes = indexed
        ambiguousWireNames = ambiguous
    }

    /// 前置ツール名(`slug__tool`)を逆引きして、該当サーバーの実行口へ元ツール名で委譲する。
    /// - 前置されていない/壊れた名前(parse 失敗)→ `unknownPrefix`(モデルにエラーが返り、ループは継続)。
    /// - 逆引きした slug に対応する executor が無い(切断済みサーバー等)→ `unknownServer`。
    public func callTool(name: String, arguments: JSONValue?) async throws -> JSONValue {
        if ambiguousWireNames.contains(name) {
            throw MultiServerToolError.ambiguousRoute(name)
        }
        // 明示 route を優先する。無い場合だけ旧 `slug__tool` の parse に戻し、既に保存された
        // チャットや短名を使う呼び出しとの後方互換を保つ。
        let resolved: (slug: String, tool: String)
        if let route = routes[name] {
            resolved = (route.slug, route.toolName)
        } else if let parsed = ToolNamespacing.parse(prefixed: name) {
            resolved = parsed
        } else {
            throw MultiServerToolError.unknownPrefix(name)
        }
        let (slug, tool) = resolved
        guard let executor = executors[slug] else {
            throw MultiServerToolError.unknownServer(slug: slug, name: name)
        }
        return try await executor.callTool(name: tool, arguments: arguments)
    }
}

/// ルーティング失敗。ChatViewModel.execute はツール実行の throw を role:"tool" のエラー文言へ載せて
/// ループを継続する(サーバー未接続や壊れた名前で会話全体を殺さない)。
public enum MultiServerToolError: Error, CustomStringConvertible {
    case unknownPrefix(String)
    case unknownServer(slug: String, name: String)
    case ambiguousRoute(String)

    public var description: String {
        switch self {
        case let .unknownPrefix(name):
            return "ツール名 \(name) は名前空間の前置(slug__tool)を持たないためどのサーバーにも振り分けられません。"
        case let .unknownServer(slug, name):
            return "ツール \(name) の接続先サーバー(\(slug))は現在接続されていません。"
        case let .ambiguousRoute(name):
            return "ツール名 \(name) は複数の接続先に対応しているため安全に実行できません。"
        }
    }
}

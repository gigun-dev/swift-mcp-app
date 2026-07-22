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

    public init(executors: [String: any MCPToolExecuting]) {
        self.executors = executors
    }

    /// 前置ツール名(`slug__tool`)を逆引きして、該当サーバーの実行口へ元ツール名で委譲する。
    /// - 前置されていない/壊れた名前(parse 失敗)→ `unknownPrefix`(モデルにエラーが返り、ループは継続)。
    /// - 逆引きした slug に対応する executor が無い(切断済みサーバー等)→ `unknownServer`。
    public func callTool(name: String, arguments: JSONValue?) async throws -> JSONValue {
        guard let (slug, tool) = ToolNamespacing.parse(prefixed: name) else {
            throw MultiServerToolError.unknownPrefix(name)
        }
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

    public var description: String {
        switch self {
        case let .unknownPrefix(name):
            return "ツール名 \(name) は名前空間の前置(slug__tool)を持たないためどのサーバーにも振り分けられません。"
        case let .unknownServer(slug, name):
            return "ツール \(name) の接続先サーバー(\(slug))は現在接続されていません。"
        }
    }
}

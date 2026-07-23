// per-tool 許可決定(R4・HITL ゲート)の永続化。(serverURL, toolName) → ToolPermissionDecision を
// UserDefaults へ保存する、接続先に中立(caldav 固有知識ゼロ・CLAUDE.md ビジョン2)なストア。
//
// 【なぜ UserDefaults か(Keychain でなく)】保存するのは「このユーザーがこのツールを常に許可/拒否
// したか」という**秘密でない設定**であり、LLMSettingsStore が base URL/model を UserDefaults に置くのと
// 同じ判断(秘密は Keychain、設定は UserDefaults)。API キーのような漏洩リスクは無い。
//
// 【キーの形】"toolPermission.<serverURL>.<toolName>"。serverURL を含めるのは、同名ツールが別サーバーに
// あっても決定が混ざらないようにするため(claude.ai もコネクタ単位で許可を持つ)。toolName は
// **originalToolName(サーバーが名乗る素の名前)**を使う。wire 名(slug__tool やハッシュ短縮名)は
// 接続の組み方で変わりうるので、決定の同一性は「サーバー URL × 素のツール名」で固定する。
import Foundation
import Kernel

/// Runner が許可決定を引く/書くための最小抽象。Sendable(Runner が TaskGroup の子から触る)。
///
/// なぜプロトコルを切るか: Runner のゲート検証(ToolCallRunnerGateTests)を UserDefaults 副作用なしで
/// 回すため。テストは「決め打ちの decision を返し、setDecision の呼び出しを記録する」in-memory 実装に
/// 差し替える(MCPToolExecuting と同じ流儀)。
public protocol ToolPermissionResolving: Sendable {
    /// 保存済みの決定を返す。未保存なら `.ask`(性悪説の既定・確認側に倒す)。
    func decision(serverURL: URL?, toolName: String) -> ToolPermissionDecision
    /// 決定を保存する(「常に許可」= `.allow` の永続化に使う)。
    func setDecision(_ decision: ToolPermissionDecision, serverURL: URL?, toolName: String)
}

/// UserDefaults 実装。actor にしない理由: UserDefaults 自体がスレッドセーフ(Apple ドキュメント保証)
/// なので、読み書きを直列化する追加の隔離は不要。`@unchecked Sendable` はその根拠に基づく明示宣言。
public final class ToolPermissionStore: ToolPermissionResolving, @unchecked Sendable {
    private let defaults: UserDefaults
    private static let keyPrefix = "toolPermission"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func decision(serverURL: URL?, toolName: String) -> ToolPermissionDecision {
        guard let raw = defaults.string(forKey: Self.key(serverURL: serverURL, toolName: toolName)),
              let decision = ToolPermissionDecision(rawValue: raw)
        else {
            // 未保存 = 一度もユーザーが判断していない → 既定は確認(ask)。
            return .ask
        }
        return decision
    }

    public func setDecision(_ decision: ToolPermissionDecision, serverURL: URL?, toolName: String) {
        let key = Self.key(serverURL: serverURL, toolName: toolName)
        // ask はストアの既定でもあるので、保存する必要はなくキーを消す(肥大化を避ける)。
        // 「常に許可(allow)」「拒否(deny)」だけを明示的に永続化する。
        if decision == .ask {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(decision.rawValue, forKey: key)
        }
    }

    /// キー生成。serverURL 未知(nil)は "unknown" に寄せる(決定は保存できるが、URL の異なる
    /// サーバー間で衝突する可能性がある——実運用では serverURL は必ず渡るので影響しない)。
    private static func key(serverURL: URL?, toolName: String) -> String {
        let server = serverURL?.absoluteString ?? "unknown"
        return "\(keyPrefix).\(server).\(toolName)"
    }
}

/// すべて `.allow` を返す no-op 実装。**テストと後方互換の既定**として使う。
///
/// なぜ必要か: ChatViewModel/ToolCallRunner の既存の呼び出し側(多数のテスト・スパイク)は
/// 許可ゲートを注入しない。それらの挙動を壊さないため、注入省略時の既定をこの「常に許可」にして、
/// **ゲートは実質無効(従来どおり即実行)**にする。本番(ChatHomeViewModel)は必ず
/// `ToolPermissionStore`(既定 ask)を注入するので、セキュリティの既定は合成ルートで ask になる。
public struct AllowAllToolPermissionStore: ToolPermissionResolving {
    public init() {}
    public func decision(serverURL: URL?, toolName: String) -> ToolPermissionDecision { .allow }
    public func setDecision(_ decision: ToolPermissionDecision, serverURL: URL?, toolName: String) {}
}

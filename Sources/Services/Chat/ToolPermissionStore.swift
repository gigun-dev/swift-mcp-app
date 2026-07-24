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
    /// **ユーザーが明示保存した**決定を返す。未保存なら `nil`(まだ一度も判断していない)。
    ///
    /// なぜ optional か(2026-07-24 refactor): 緩和(readOnly 自動許可)を evaluate から
    /// defaultDecision(未保存の既定を決める層)へ移したため、gate は「stored ?? defaultDecision」で
    /// 実効決定を組む。stored が nil のときだけ annotations 由来の既定を当て、明示保存があればそれを
    /// **無条件に尊重**する(明示 .ask を hint 緩和で握りつぶさないため)。
    func storedDecision(serverURL: URL?, toolName: String) -> ToolPermissionDecision?
    /// 保存済みの決定を返す。未保存なら `.ask`(性悪説の既定・確認側に倒す)。
    /// storedDecision の薄いラッパ(後方互換; 設定画面等が「明示保存が無ければ ask 相当」で読む用途)。
    func decision(serverURL: URL?, toolName: String) -> ToolPermissionDecision
    /// 決定を保存する(3 値すべて明示決定として永続化。ask も含む — 下の実装コメント参照)。
    func setDecision(_ decision: ToolPermissionDecision, serverURL: URL?, toolName: String)
    /// 明示決定を消して「未保存(= annotations 由来の既定に従う)」へ戻す。設定画面の「既定に戻す」用。
    func clearDecision(serverURL: URL?, toolName: String)
}

extension ToolPermissionResolving {
    /// 既定実装: storedDecision があればそれ、無ければ性悪説の既定 `.ask`。
    /// (decision を storedDecision の薄いラッパにして正典を二重化しない)。
    public func decision(serverURL: URL?, toolName: String) -> ToolPermissionDecision {
        storedDecision(serverURL: serverURL, toolName: toolName) ?? .ask
    }
}

/// UserDefaults 実装。actor にしない理由: UserDefaults 自体がスレッドセーフ(Apple ドキュメント保証)
/// なので、読み書きを直列化する追加の隔離は不要。`@unchecked Sendable` はその根拠に基づく明示宣言。
public final class ToolPermissionStore: ToolPermissionResolving, @unchecked Sendable {
    private let defaults: UserDefaults
    private static let keyPrefix = "toolPermission"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func storedDecision(serverURL: URL?, toolName: String) -> ToolPermissionDecision? {
        guard let raw = defaults.string(forKey: Self.key(serverURL: serverURL, toolName: toolName)),
              let decision = ToolPermissionDecision(rawValue: raw)
        else {
            // 未保存 = 一度もユーザーが判断していない → nil(gate 側で defaultDecision を当てる)。
            // ask はキーを持たない設計(setDecision 参照)なので、ここに ask が保存されることは無い。
            return nil
        }
        return decision
    }

    public func setDecision(_ decision: ToolPermissionDecision, serverURL: URL?, toolName: String) {
        // 3 値すべて(allow/ask/deny)を明示決定として永続化する。
        //
        // 2026-07-24 refactor 撤回: 旧実装は「ask は既定なのでキーを消す(肥大化回避)」としていたが、
        // 緩和(readOnly 自動許可)を gate の defaultDecision へ移した後は **「未保存(キー無し)」と
        // 「明示 ask(キーあり)」を区別しなければならない**。区別しないと storedDecision が nil を返し、
        // gate が readOnly closed trusted を defaultDecision で .allow に昇格させてしまい、ユーザーが
        // 設定画面で明示した「承認が必要(.ask)」が無視される(=今回修正した穴が end-to-end で再発)。
        // 肥大化はユーザーが明示的に触ったツールだけキーが増えるので実害なし(既定へ戻すのは clearDecision)。
        defaults.set(decision.rawValue, forKey: Self.key(serverURL: serverURL, toolName: toolName))
    }

    public func clearDecision(serverURL: URL?, toolName: String) {
        // 明示決定を消す = 未保存へ戻す(storedDecision が nil を返し、gate が annotations 由来の既定を当てる)。
        defaults.removeObject(forKey: Self.key(serverURL: serverURL, toolName: toolName))
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
    // storedDecision で `.allow` を返す = 「全ツールをユーザーが明示的に常時許可した」相当。gate は
    // stored を無条件に尊重するので、annotations に関係なく即実行になる(緩和層すら通らず常に proceed)。
    // decision(...) は protocol の既定実装が storedDecision を包むので、こちらも .allow を返す。
    public func storedDecision(serverURL: URL?, toolName: String) -> ToolPermissionDecision? { .allow }
    public func setDecision(_ decision: ToolPermissionDecision, serverURL: URL?, toolName: String) {}
    public func clearDecision(serverURL: URL?, toolName: String) {}
}

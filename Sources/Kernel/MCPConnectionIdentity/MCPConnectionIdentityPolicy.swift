// 登録簿の編集後に、現在の MCP 接続をそのまま再利用してよいか判定する純関数。
//
// 接続済みの ReadyConnection は接続時点の name / URL / slug を保持する。一方、設定画面では
// 同じ serverID の name / URL を後から編集でき、別エントリの追加・削除によって期待 slug も
// 変わりうる。serverID が同じという理由だけで ready 接続を再利用すると、表示名と接続先が
// 登録簿に追従しないだけでなく、同じ slug の executor が2本できて tools/call の配送先が
// Dictionary の上書き順に左右される。
//
// 判定を ConnectionsManager の分岐へ埋め込まず Kernel に置くのは、ネットワーク無しでこの
// 境界を固定するため。どれか1項目でも変わった接続は古いものとして破棄・再接続する。
import Foundation

/// 1接続を登録簿と照合するのに必要な不変値。serverID が同じでも、この3項目のどれかが
/// 異なれば接続時点の情報は古い。値型にまとめることで比較条件の追加漏れと長い引数列を防ぐ。
public struct MCPConnectionIdentity: Equatable, Sendable {
    public let name: String
    public let url: URL
    public let slug: String

    public init(name: String, url: URL, slug: String) {
        self.name = name
        self.url = url
        self.slug = slug
    }
}

public enum MCPConnectionIdentityPolicy {
    public static func requiresReconnect(
        connected: MCPConnectionIdentity,
        expected: MCPConnectionIdentity
    ) -> Bool {
        connected != expected
    }
}

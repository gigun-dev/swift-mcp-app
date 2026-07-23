// MCP サーバー URL の「正規化キー」を作る純関数(プラットフォーム非依存 Kernel)。
//
// 【なぜ canonical か = 再追加での serverID 孤児化バグの根修正】
// OAuth コネクタを再追加(同じ MCP サーバー URL をもう一度 add)するたびに、
// ServerRegistryStore.add が新 UUID の別エントリを append していた。その結果 serverID が変わり、
// 過去チャットの履歴カード provenance(serverID を記録している)が孤児化して placeholder に
// 落ちる実機バグの根因になっていた。「同じ MCP エンドポイントか」を URL 表層の揺れ(末尾スラッシュ・
// host の大文字小文字・既定ポートの明示/省略・fragment)を吸収して判定できるようにし、
// 再追加が既存エントリを再利用(= serverID を温存)できるようにするのがこの型の役目。
//
// 【resolver の serverURL 厳密等価との整合 = provenance を壊さない】
// この canonicalKey は「add の冪等判定」にだけ使う照合キーであって、保存する値ではない。
// 既存エントリの url 文字列(absoluteString)は add 冪等化後も **温存**する(上書きしない)。
// そのため:
//   - Keychain トークンのキー(kSecAttrAccount = serverURL.absoluteString)は変わらない
//   - 既存カードの provenance が持つ serverURL の「厳密等価」照合も壊れない
// つまり canonical 化は「どのエントリを再利用するか」の判断だけに閉じ、既存の厳密等価な世界には
// 一切漏らさない。だから canonicalKey が多少アグレッシブに正規化しても provenance は安全。
import Foundation

/// MCP サーバー URL の同一性を判定するための正規化ユーティリティ(純関数・状態を持たない enum)。
public enum ServerURLIdentity {
    /// 「同じ MCP エンドポイントか」を判定するための正規化キーを返す。
    ///
    /// 正規化の内容(表層の揺れだけを畳み、意味を持ちうる差は温存する):
    ///   - scheme を小文字化(URL scheme は case-insensitive・RFC 3986)
    ///   - host を小文字化(host も case-insensitive)
    ///   - 既定ポート(http:80 / https:443)は除去し、非既定ポートは保持(:80 明示と省略を同一視)
    ///   - path 末尾のスラッシュを **1個だけ** 除去(空 path や "/" は "" に落とす)。中間のスラッシュは
    ///     触らない(`/a//b` の意味を勝手に変えない)
    ///   - fragment は除去(サーバー側リクエストに乗らない・同一エンドポイントの区別に使えない)
    ///   - query は保持(意味を持ちうる ——別テナント・別モード等 ——ので触らない)
    ///   - user/password 情報があれば保持(通常 MCP URL には無いが、あるなら別資格情報=別接続)
    ///
    /// 分解不能な URL(URLComponents が host を取れない等の異常系)は、絶対文字列を小文字化した
    /// フォールバックキーを返す ——判定不能で衝突させるより、素の文字列比較に倒す方が安全
    /// (少なくとも「完全に同じ文字列」は同一視できる)。
    public static func canonicalKey(_ url: URL) -> String {
        // resolvingAgainstBaseURL: true で相対 URL も解決してから分解する。
        // components が nil、または host が取れない(scheme 相対や mailto 等の異常系)は
        // 正規化を諦めて絶対文字列の小文字化にフォールバックする。
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return url.absoluteString.lowercased()
        }

        // scheme・host を小文字化(どちらも RFC 上 case-insensitive)。
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        // 既定ポートは除去して「:443 明示」と「省略」を同一視する。非既定ポートは接続先が違うので保持。
        if let scheme = components.scheme, let port = components.port, isDefaultPort(port, for: scheme) {
            components.port = nil
        }

        // fragment は同一エンドポイント判定に無意味(サーバーへ送られない)ので落とす。
        components.fragment = nil

        // path 末尾スラッシュを1個だけ削る。"/mcp/" と "/mcp"、"/" と "" を同一視するため。
        // 中間スラッシュ(`/a//b`)は意味を変えうるので触らない ——末尾1個だけに限定する。
        if components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        } else if components.path == "/" {
            // ルートだけの "/" は空 path と同一視する(末尾スラッシュ有無の吸収の一部)。
            components.path = ""
        }

        // query は保持(上のコメント)。user/password も components に残っているので保持される。
        // 組み立て直せない異常系はフォールバック。
        guard let normalized = components.string else {
            return url.absoluteString.lowercased()
        }
        return normalized
    }

    /// scheme に対する既定ポートか(http:80 / https:443)。ws/wss は MCP Streamable HTTP では
    /// 使わないが、将来 transport が増えても素直に足せるよう明示的な判定に切り出しておく。
    private static func isDefaultPort(_ port: Int, for scheme: String) -> Bool {
        switch scheme {
        case "http": return port == 80
        case "https": return port == 443
        default: return false
        }
    }
}

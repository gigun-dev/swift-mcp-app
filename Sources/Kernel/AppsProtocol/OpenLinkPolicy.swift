// ui/open-link の URL 検証(プラットフォーム非依存の純関数・監査 2026-07-18 HIGH #2)。
//
// 【なぜ Kernel に置くか】この検証はサンドボックス(WKWebView)脱出経路の入口になりうる
// (カード HTML は任意の MCP サーバーが提供する — CLAUDE.md ビジョン2で AppsBridge は
// caldav 非依存。悪意/バグのあるカードが javascript: や file: スキームの URL を
// ui/open-link に載せてくる可能性を潰す)。判定自体は URL 文字列 → 許可/拒否の純粋な写像で
// UIKit・WKWebView に一切依存しないため、Kernel に置いて swift-testing で高速にテストできる
// (CLAUDE.md「Kernel はプラットフォーム非依存」)。
//
// 【許可スキームを http/https だけに絞る理由】apps.mdx:965 は
// 「Host SHOULD open the URL in the user's default browser or a new tab」とだけ言い、
// 許可スキームを規定しない。ブラウザ/新規タブで開く用途は http/https に限られるのが実務上の
// 自然な解釈であり、file: / javascript: / data: 等はブラウザ起動の文脈で意味を持たない
// どころか、そのまま UIApplication.open に渡すとローカルファイルアクセスや任意コード実行の
// 経路になりうる(javascript: はホスト側で評価されなくても、ユーザーを騙して Safari 等の
// 別アプリに渡った先で誤解を招く URL 表示に使われうる)。ホワイトリスト方式(許可を列挙)を
// ブラックリスト方式(危険なものを列挙)より優先するのは、未知の新スキームに対して
// 安全側(拒否)に倒れるため。
import Foundation

public enum OpenLinkPolicy {
    /// `url` 文字列を検証し、開いてよい `URL` を返す。スキームが http/https でない・
    /// URL として解釈できない場合は nil(呼び出し側は spec の error response
    /// `{code: -32000, message: "Invalid URL"}` 相当を返す・apps.mdx:965-985)。
    public static func resolve(urlString: String) -> URL? {
        guard let url = URL(string: urlString), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        guard scheme == "http" || scheme == "https" else { return nil }
        return url
    }
}

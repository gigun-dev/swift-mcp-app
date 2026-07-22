// MCP サーバー登録時のエンドポイント URL 検証(プラットフォーム非依存の純関数)。
//
// 【なぜ Kernel に切り出したか】元は SettingsSheet(Features)にインラインで
// `URL(string:)` + `scheme == "https"` + `host != nil` の3条件だけ書いていた。これが
// シミュレータ実機検証(2026-07-22)で実バグとして噴いた:
//
//   フォームの URL 欄にあった初期値 "https://" と、ユーザーが貼り付けたフル URL が
//   連結され "https://http://tdr-concierge..." になった。
//   ところが `URL(string:)` はこれを「scheme=https, host=http, path=//tdr-...」と
//   解釈するので、上の3条件を**全部満たして通ってしまう**。保存ボタンが有効化され、
//   壊れたエントリが ServerRegistry に永続化され、接続時に NSURLErrorDomain -1003
//   ("A server with the specified hostname could not be found.") が出る。
//   ユーザー視点では「https 必須と書いてあるのに http を入れたら保存できて、
//   わけの分からないエラーになる」— 最悪の体験。
//
// 判定は「文字列 → 許可 URL / 拒否理由」の純粋な写像で SwiftUI に一切依存しないため、
// OpenLinkPolicy(ui/open-link の URL 検証)と同じ流儀で Kernel に置き、swift-testing で
// 上記の二重スキームを含む境界ケースを固定する(CLAUDE.md「Kernel はプラットフォーム非依存」)。
//
// 【拒否理由を型で返す理由】呼び出し側(SettingsSheet)は「何が悪いのか」を日本語で
// 出し分けたい。Bool や Optional<URL> だと「https:// で始まる有効な URL を入力してください」
// という汎用文しか書けず、二重スキームのときにユーザーは自分が何をしたか気づけない
// (実機で踏んだのがまさにこれ)。文言そのものは UI の関心なので Kernel には置かず、
// Rejection という「理由の列挙」までを Kernel の責務とする。
import Foundation

public enum MCPEndpointPolicy {
    /// 検証に失敗した理由。UI はこれを見て文言を出し分ける(文言は Features 側に置く)。
    /// (Error 準拠は `Result` の Failure 制約を満たすため。throw する想定は無く、
    /// あくまで「拒否理由を型で運ぶ」ためのタグ。)
    public enum Rejection: Error, Equatable, Sendable {
        /// 空文字(トリム後)。まだ何も入力していない状態。
        case empty
        /// "://" が2回以上現れる。複数 URL の連結や貼り付け事故を示す。
        case doubleScheme
        /// scheme が https でない(http や scheme 無しを含む)。
        case notHTTPS
        /// host が空、または実在しうる形でない(ドットも localhost でもない)。
        case invalidHost
        /// URL としてそもそもパースできない。
        case malformed
    }

    /// `urlString` を検証し、登録してよい `URL` を返す。前後の空白・改行はトリムする
    /// (iOS のペーストやソフトウェアキーボードは末尾に空白/改行を混ぜやすく、
    /// これを弾くとユーザーには理由が分からない。従来の SettingsSheet の挙動を踏襲)。
    /// - Parameter allowInsecureLoopback: `true` のときだけ、開発用の exact loopback
    ///   (`localhost` / `127.0.0.1` / `::1`)に限って平文 HTTP を許す。呼び出し側が build
    ///   configuration を明示注入する設計にして、Kernel 自身は `#if DEBUG` や iOS に依存しない。
    ///   既定は `false`。引数を渡し忘れた経路や Release 相当の利用が安全側へ倒れる。
    public static func resolve(
        urlString: String,
        allowInsecureLoopback: Bool = false
    ) -> Result<URL, Rejection> {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.empty) }

        // 【二重スキームの検出を URL パースより先に置く理由】"https://http://host/mcp" は
        // URL としては合法にパースできてしまう(host="http")ので、パース後の検査では
        // 「host にドットが無い」という間接的な理由でしか弾けず、ユーザーに返す文言が
        // 的外れになる。文字列段階で "://" の出現回数を数えれば意図がそのまま表現でき、
        // かつ "https://https://..."(同スキームの二重貼り)も同じ経路で拾える。
        // なお正規の URL でも path/query に "://" が現れうる(例: リダイレクト URL を
        // クエリに載せる)が、MCP エンドポイントは素朴な /mcp パスであり、
        // 誤検出より二重スキームの取りこぼしの方が痛い(実機で踏んだのは後者)ため
        // 単純な出現回数カウントで安全側に倒す。将来クエリ付きの正当な URL を登録したい
        // 要求が出たら、ここを「scheme 部を取り除いた残りに "://" が無いこと」に緩める。
        if occurrences(of: "://", in: trimmed) > 1 { return .failure(.doubleScheme) }

        guard let url = URL(string: trimmed) else { return .failure(.malformed) }

        // scheme 無し("example.com/mcp")もここで .notHTTPS に落とす。ユーザーへの案内は
        // どちらも「https:// で始めてください」で同じなので、理由を分ける実益が無い。
        //
        let normalizedHost = url.host?.lowercased()
        let isExactLoopback = normalizedHost == "localhost"
            || normalizedHost == "127.0.0.1"
            || normalizedHost == "::1"

        // 【http を原則拒む理由(既存 SettingsSheet のコメントを引き継ぐ)】MCP Apps の接続は
        // OAuth 2.1 前提で、本番エンドポイントは https(caldav も Workers 上の https)。
        // 平文 http を許すとトークン・tool 引数・tool 結果が平文で流れる。唯一の例外は、
        // Simulator から Mac 上の開発 MCP を検証するため呼び出し側が明示許可した exact loopback。
        // LAN IP、`.local`、公開 host は DEBUG でも許さない。iOS 側の ATS 例外も Debug app の
        // `NSAllowsLocalNetworking` だけに限定し、Release の安全な既定を崩さない。
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && allowInsecureLoopback && isExactLoopback)
        else {
            return .failure(.notHTTPS)
        }

        guard let host = url.host, !host.isEmpty else { return .failure(.invalidHost) }

        // 【ドット必須 + localhost 例外という判断】"https://http://..." の host は "http" の
        // ように、タイプミス/連結事故の残骸はドットを含まない単一ラベルになることが多い。
        // 公開 MCP サーバーの FQDN は必ずドットを含むので「ドット必須」は実用上ほぼ無害な
        // 強い網になる。一方 localhost だけはドット無しで実在しうる正当なホストであり、
        // 上記のとおり将来のローカル開発(https 自己署名 / トンネル)で使う可能性が高いので、
        // 今のうちに例外として通しておく(ここで弾くと、その時に「なぜ保存できない」を
        // もう一度デバッグする羽目になる)。IPv6 リテラルなど他の dotless host は
        // 現状ユースケースが無いため拒否側に倒す — 必要になったら緩める。
        guard isExactLoopback || host.contains(".") else { return .failure(.invalidHost) }

        return .success(url)
    }

    /// 部分文字列の出現回数(重なりは数えない)。Foundation だけで完結させるための小道具。
    private static func occurrences(of needle: String, in haystack: String) -> Int {
        var count = 0
        var searchStart = haystack.startIndex
        while let range = haystack.range(of: needle, range: searchStart ..< haystack.endIndex) {
            count += 1
            searchStart = range.upperBound
        }
        return count
    }
}

// ツール名の名前空間化(M2・複数サーバー同時接続)。
//
// 【なぜ要るか】M2 で複数の MCP サーバーへ同時接続し、それぞれの tools/list を1つの LLM に
// 合成して渡す。ところがサーバーが違えば同名ツール(例: 2つのカレンダー系サーバーがどちらも
// `list-events` を持つ)が衝突しうる。LLM が返す tool_call.name だけでは「どのサーバーのツールか」
// を復元できない。そこで **サーバーごとに決定的な slug を振り、ツール名を `slug__tool` に前置**して
// 一意化し、実行時に `slug__tool` → (サーバー, 元のツール名) へ逆引きできるようにする。
//
// 【なぜ Kernel(純関数)に置くか】slug 生成・前置・逆引きは文字列操作だけで完結し、swift-sdk にも
// UIKit にも依存しない。ルーティング表の正しさ(前置と逆引きが常に対称)は単体テストで固定したい
// (Tests/KernelTests)。実際に proxy へ委譲する MultiServerToolExecutor は Services に置くが、
// 名前の変換ロジックそのものは中立な純関数としてここに隔離する(CLAUDE.md ビジョン2)。
//
// 【OpenAI の name 制約】LLM(OpenAI 互換)のツール名は `^[a-zA-Z0-9_-]{1,64}$`(ToolConversion の
// name 制約)。slug は `[a-z0-9-]` のみに正規化し、`slug__tool` 全体が 64 字を超えないよう slug を
// 切り詰める(切り詰めは呼び出し側が maxLength で指定する — その server の最長ツール名から算出する)。
// セパレータ `__`(アンダースコア2つ)を使う理由: slug は `[a-z0-9-]` のみ(アンダースコアを含まない)
// なので、`__` は slug 内には決して現れない = 逆引きで「最初の `__`」を境界にすれば slug と元ツール名を
// 曖昧さなく分離できる(元ツール名側に `__` が含まれても、境界は最初の `__` 固定なので影響しない)。
import Foundation

public enum ToolNamespacing {
    /// 前置に使うセパレータ。slug(`[a-z0-9-]`)には現れない2文字を選ぶ(上のファイルコメント参照)。
    public static let separator = "__"

    /// サーバー表示名から決定的な slug を生成する。
    ///
    /// - 小文字化 → `[a-z0-9-]` 以外を除去(空白・記号・日本語などは落ちる)。
    /// - 連続ハイフンは1つに畳み、先頭末尾のハイフンは削る(見栄えと安定性のため)。
    /// - 結果が空になったら `"server"` にフォールバック(名前が全部非 ASCII のときなど)。
    /// - `maxLength` を超えたら切り詰める(OpenAI の 64 字制約を `slug__tool` 全体で守るため。
    ///   呼び出し側が「64 - separator - その server の最長ツール名長」を渡す)。
    /// - `existing` に既にある slug と衝突したら `-2`, `-3`, … を付けて一意化する
    ///   (同名サーバーを2つ登録したケース。maxLength を尊重しつつサフィックスぶんを削って収める)。
    ///
    /// - Parameters:
    ///   - name: サーバーの表示名(ユーザーが付けた name)。
    ///   - existing: 既に払い出し済みの slug 集合(この呼び出しで衝突回避に使う)。
    ///   - maxLength: slug の最大長(既定 48。`slug__tool` 全体で 64 に収めるため呼び出し側が調整)。
    /// - Returns: 一意な slug。
    public static func slug(for name: String, existing: Set<String>, maxLength: Int = 48) -> String {
        let cap = max(1, maxLength)
        let normalized = normalizedBase(name)
        let base = cappedBase(normalized, cap: cap)

        if !existing.contains(base) { return base }

        // 2から始める無限列を候補へ写像し、最初の空きを取る。衝突探索と文字列整形を
        // 分離することで、slug() 本体が正規化の分岐を抱え込まないようにする。
        return sequence(first: 2, next: { $0 + 1 })
            .lazy
            .map { suffixedCandidate(base: base, suffix: $0, cap: cap) }
            .first(where: { !existing.contains($0) })!
    }

    /// 表示名をASCII slugの素材へ正規化する。置換後に正規表現で連続区切りを畳むため、
    /// 文字走査と「直前がハイフンか」という状態管理を分けられる。
    private static func normalizedBase(_ name: String) -> String {
        let mapped = name.lowercased().map { character in
            character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
        }
        let collapsed = String(mapped).replacingOccurrences(
            of: "-+",
            with: "-",
            options: .regularExpression
        )
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "server" : trimmed
    }

    /// OpenAIのname上限から呼び出し側が算出したcapへ、素のslugを収める。
    private static func cappedBase(_ base: String, cap: Int) -> String {
        guard base.count > cap else { return base }
        let trimmed = String(base.prefix(cap))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // 既存挙動を維持するため、極端に小さいcapで素材が空になった場合もserverへ戻す。
        return trimmed.isEmpty ? "server" : trimmed
    }

    /// `-N`を含めてcapへ収めた衝突回避候補を組み立てる。
    private static func suffixedCandidate(base: String, suffix: Int, cap: Int) -> String {
        let suffixString = "-\(suffix)"
        let room = max(1, cap - suffixString.count)
        let trimmed = String(base.prefix(room))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return (trimmed.isEmpty ? "server" : trimmed) + suffixString
    }

    /// slug と元ツール名から LLM へ見せる前置ツール名(`slug__tool`)を組む。
    public static func prefixed(slug: String, tool: String) -> String {
        slug + separator + tool
    }

    /// 前置ツール名(`slug__tool`)を slug と元ツール名へ逆引きする。
    ///
    /// **最初の `__` を境界にする**(slug は `[a-z0-9-]` のみで `__` を含まないため、最初の `__` が
    /// 必ず slug と元ツール名の境界になる)。境界が無い/ slug 側 or ツール名側が空になる形は nil を返す
    /// (前置されていない生の名前・壊れた名前を「未知」として弾く — 呼び出し側がエラーにできる)。
    public static func parse(prefixed name: String) -> (slug: String, tool: String)? {
        guard let range = name.range(of: separator) else { return nil }
        let slug = String(name[..<range.lowerBound])
        let tool = String(name[range.upperBound...])
        guard !slug.isEmpty, !tool.isEmpty else { return nil }
        return (slug, tool)
    }
}

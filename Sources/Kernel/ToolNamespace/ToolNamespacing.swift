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
        // 1) 正規化: 小文字化して各文字を [a-z0-9-] に絞る(それ以外はハイフンに寄せて語境界を残す)。
        let lowered = name.lowercased()
        var mapped = ""
        for ch in lowered {
            if ch.isASCII, (ch.isLetter || ch.isNumber) {
                mapped.append(ch)
            } else {
                // 空白・記号・非 ASCII はハイフンに寄せる(語の切れ目を潰さない)。連続はあとで畳む。
                mapped.append("-")
            }
        }
        // 2) 連続ハイフンを1つに畳み、先頭末尾のハイフンを削る。
        var collapsed = ""
        var lastWasHyphen = false
        for ch in mapped {
            if ch == "-" {
                if !lastWasHyphen { collapsed.append(ch) }
                lastWasHyphen = true
            } else {
                collapsed.append(ch)
                lastWasHyphen = false
            }
        }
        var base = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        // 3) 空フォールバック。
        if base.isEmpty { base = "server" }
        // 4) maxLength への切り詰め(サフィックス無しの素の長さで先に丸める)。
        let cap = max(1, maxLength)
        if base.count > cap {
            base = String(base.prefix(cap))
            // 切り詰めで末尾がハイフンになったら削る(見栄え・"-2" と繋がって "--2" になるのを避ける)。
            base = base.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if base.isEmpty { base = "server" }
        }
        // 5) 衝突回避: そのままで空きならそれを、埋まっていれば -2, -3, … を付ける。
        //    サフィックスを足すと cap を超えうるので、超えるぶんは base を削って収める。
        if !existing.contains(base) { return base }
        var suffix = 2
        while true {
            let suffixStr = "-\(suffix)"
            let room = max(1, cap - suffixStr.count)
            var trimmedBase = String(base.prefix(room))
            trimmedBase = trimmedBase.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if trimmedBase.isEmpty { trimmedBase = "server" }
            let candidate = trimmedBase + suffixStr
            if !existing.contains(candidate) { return candidate }
            suffix += 1
        }
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

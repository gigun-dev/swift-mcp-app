// SSE の tool_calls delta を蓄積して完成形の [ToolCall] に確定させる純ロジック。
//
// 出典・蓄積規則(docs/design/02-chat-llm.md §2。一次資料は OpenAI function-calling
// ガイド https://developers.openai.com/docs/guides/function-calling の streaming セクション
// のリファレンス実装):各 delta 要素は `index` を持ち、**最初の delta に id と
// function.name が丸ごと載り、以降の delta は function.arguments の断片だけ**が届く。
// index をキーにした辞書に積み、arguments は文字列連結して JSON を完成させる。
//
// 防御的にしている点(仕様上は起きないはずだが、互換プロバイダの実装揺れに備える):
// - id/name が複数回・あるいは最初以外の delta で届いても上書きでなく「後勝ち」を許容する
//   (空文字列で上書きされて消えるほうが実害が大きいので、非 nil の値だけ採用する)。
// - index が飛び番・逆順で来ても最終的な並びは index 昇順に整列し直す
//   (out-of-order ネットワーク到達や、プロバイダがチャンクをまとめて送る場合に耐える)。
import Foundation

/// tool_calls delta のストリームを受け取り、最終的な `[ToolCall]` を確定させる。
/// 呼び出し側(Services/LLM の OpenAICompatClient)は SSE チャンクを読むたびに
/// `accumulate(_:)` を呼び、ストリーム終端(`[DONE]`)で `finalize()` を1回呼ぶ想定。
public struct ToolCallAccumulator {
    /// index → 蓄積中の断片。id・name は届いた時点のスナップショット、
    /// arguments は届いた断片を順番に連結した文字列。
    private struct Pending {
        var id: String?
        var name: String?
        var argumentsFragments: String = ""
    }

    private var pendingByIndex: [Int: Pending] = [:]

    public init() {}

    /// 1チャンクぶんの tool_calls delta 配列を取り込む。
    /// 1チャンクに複数 index(= 複数 tool_call を並行生成中)が混ざることもあるため配列で受ける。
    public mutating func accumulate(_ deltas: [ToolCallDelta]) {
        for delta in deltas {
            var pending = pendingByIndex[delta.index] ?? Pending()
            // id/name は「非 nil の値が届いたら採用」(空データでの上書きを避ける)。
            if let id = delta.id { pending.id = id }
            if let name = delta.function?.name { pending.name = name }
            if let argumentsFragment = delta.function?.arguments {
                pending.argumentsFragments += argumentsFragment
            }
            pendingByIndex[delta.index] = pending
        }
    }

    /// 蓄積結果を index 昇順の `[ToolCall]` に確定させる。
    /// id/name が最後まで届かなかった index は不完全とみなし、空文字列で埋めて欠落を可視化する
    /// (呼び出し側の JSON パースで失敗させて異常に気づけるようにする——ここで握りつぶさない)。
    public func finalize() -> [ToolCall] {
        pendingByIndex.keys.sorted().map { index in
            let pending = pendingByIndex[index]!
            return ToolCall(
                id: pending.id ?? "",
                function: .init(
                    name: pending.name ?? "",
                    arguments: pending.argumentsFragments
                )
            )
        }
    }
}

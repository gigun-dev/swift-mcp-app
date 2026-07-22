import Kernel

/// 最後のユーザー発話以降を表示履歴とLLM wire履歴の両方から巻き戻す。
///
/// assistant(tool_calls)とrole:toolの厳密なペアは、最後のuser以降を丸ごと削ることで維持される。
/// usageは実際に消費済みなので巻き戻さず、再送分も累計へ加える。
enum ChatRetryPlanner {
    static func rewind(turns: inout [ChatTurn], wireMessages: inout [ChatMessage]) -> String? {
        guard let turnIndex = turns.lastIndex(where: { $0.role == .user }),
              let wireIndex = wireMessages.lastIndex(where: { $0.role == .user })
        else { return nil }

        let text = turns[turnIndex].text
        turns.removeSubrange(turnIndex...)
        wireMessages.removeSubrange(wireIndex...)
        return text
    }
}

import Kernel

/// 最後のユーザー発話以降を表示履歴とLLM wire履歴の両方から巻き戻す。
///
/// assistant(tool_calls)とrole:toolの厳密なペアは、最後のuser以降を丸ごと削ることで維持される。
/// usageは実際に消費済みなので巻き戻さず、再送分も累計へ加える。
enum ChatRetryPlanner {
    static func rewind(turns: inout [ChatTurn], wireMessages: inout [ChatMessage]) -> String? {
        guard let turnIndex = turns.lastIndex(where: { $0.role == .user }) else { return nil }
        return rewind(userTurnAt: turnIndex, turns: &turns, wireMessages: &wireMessages)
    }

    /// 指定した表示上のuser発話から後ろを、表示・wireの双方で丸ごと切り戻す。
    /// userの出現順で対応付けるため、途中にtool-only assistantやrole:toolが何個あっても
    /// assistant(tool_calls)/toolのペアを途中で分断しない。
    static func rewind(
        userTurnAt turnIndex: Int,
        turns: inout [ChatTurn],
        wireMessages: inout [ChatMessage]
    ) -> String? {
        guard turns.indices.contains(turnIndex), turns[turnIndex].role == .user else { return nil }

        let userOrdinal = turns[..<turnIndex].filter { $0.role == .user }.count
        let wireUserIndices = wireMessages.indices.filter { wireMessages[$0].role == .user }
        guard wireUserIndices.indices.contains(userOrdinal) else { return nil }
        let wireIndex = wireUserIndices[userOrdinal]

        let text = turns[turnIndex].text
        turns.removeSubrange(turnIndex...)
        wireMessages.removeSubrange(wireIndex...)
        return text
    }
}

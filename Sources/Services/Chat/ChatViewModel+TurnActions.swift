import Foundation
import Kernel

@MainActor
extension ChatViewModel {
    public func retryLastTurn() async {
        guard !isRunning,
              let retryText = ChatRetryPlanner.rewind(turns: &turns, wireMessages: &wireMessages)
        else { return }

        errorMessage = nil
        await send(retryText)
    }

    /// user発話の編集前に、その発話以降を安全に切り戻して本文を返す。
    /// 呼び出し側は返した本文をcomposerへ入れ、ユーザーが確定するまで再送しない。
    public func rewindForEditing(userTurnAt turnIndex: Int) -> String? {
        guard !isRunning else { return nil }
        if editingSnapshot != nil { cancelEditing() }
        let snapshot = (turns: turns, wireMessages: wireMessages)
        guard
              let text = ChatRetryPlanner.rewind(
                  userTurnAt: turnIndex,
                  turns: &turns,
                  wireMessages: &wireMessages
              )
        else { return nil }
        editingSnapshot = snapshot
        errorMessage = nil
        return text
    }

    /// 編集した文を送る直前に退避を破棄し、rewind後の状態を確定する。
    public func commitEditing() {
        editingSnapshot = nil
    }

    /// キーボードを閉じるなど、送信せず編集を終えた場合に元の会話を復元する。
    public func cancelEditing() {
        guard let snapshot = editingSnapshot else { return }
        turns = snapshot.turns
        wireMessages = snapshot.wireMessages
        editingSnapshot = nil
        onTurnSettled?()
    }

    public var isEditingUserTurn: Bool { editingSnapshot != nil }

    /// assistantの評価を排他的に切り替える。同じ評価の再タップは解除する。
    public func toggleFeedback(_ feedback: ChatTurnFeedback, assistantTurnAt turnIndex: Int) {
        guard turns.indices.contains(turnIndex), turns[turnIndex].role == .assistant else { return }
        turns[turnIndex].feedback = turns[turnIndex].feedback == feedback ? nil : feedback
        let selectedFeedback = turns[turnIndex].feedback
        var fields = [
            "chat_id": sessionId,
            "assistant_index": String(turnIndex),
            "feedback.id": turns[turnIndex].feedbackEventID ?? UUID().uuidString,
            "feedback.rating": selectedFeedback.map { String(describing: $0) } ?? "none",
            "response": turns[turnIndex].text
        ]
        if let context = turns[turnIndex].telemetryContext {
            fields["telemetry.trace_parent"] = context
        }
        telemetry.event("chat.feedback", fields: fields, level: .info)
        onTurnSettled?()
    }

    public func regenerateResponse(fromAssistantTurnAt turnIndex: Int) async {
        guard !isRunning, turns.indices.contains(turnIndex), turns[turnIndex].role == .assistant,
              let userIndex = turns[..<turnIndex].lastIndex(where: { $0.role == .user }),
              let text = ChatRetryPlanner.rewind(
                  userTurnAt: userIndex,
                  turns: &turns,
                  wireMessages: &wireMessages
              )
        else { return }
        errorMessage = nil
        await send(text)
    }
}

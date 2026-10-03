import Kernel

/// 永続化した表示ターンから、再開後のLLMへ渡す厳密なwire履歴を復元する。
enum RestoredWireHistoryBuilder {
    static func build(from turns: [ChatTurn]) -> [ChatMessage] {
        var messages: [ChatMessage] = []
        for (turnIndex, turn) in turns.enumerated() {
            if turn.role == .user {
                messages.append(ChatMessage(role: .user, content: turn.text))
                continue
            }
            guard turn.role == .assistant else { continue }

            let restorableSteps = turn.toolSteps.enumerated().compactMap { stepIndex, step -> (ToolCall, String)? in
                guard let arguments = step.argumentsJSON, let result = step.resultJSON else { return nil }
                let callId = "restored-\(turnIndex)-\(stepIndex)"
                return (
                    ToolCall(
                        id: callId,
                        function: .init(name: step.toolName, arguments: arguments)
                    ),
                    result
                )
            }
            if !restorableSteps.isEmpty {
                messages.append(ChatMessage(
                    role: .assistant,
                    content: turn.text.isEmpty ? nil : turn.text,
                    toolCalls: restorableSteps.map(\.0)
                ))
                messages.append(contentsOf: restorableSteps.map { call, result in
                    ChatMessage(role: .tool, content: result, toolCallId: call.id)
                })
            } else if !turn.text.isEmpty {
                messages.append(ChatMessage(role: .assistant, content: turn.text))
            }
        }
        return messages
    }
}

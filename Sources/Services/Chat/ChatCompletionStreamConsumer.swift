import Kernel

/// LLMイベント列を1回分の確定応答へ畳み込み、本文deltaだけを逐次UIへ通知する。
@MainActor
enum ChatCompletionStreamConsumer {
    struct Completion {
        let text: String
        let finishReason: FinishReason
        let toolCalls: [ToolCall]
        let usage: Usage?
    }

    static func consume(
        _ stream: AsyncThrowingStream<LLMEvent, Error>,
        onTextChanged: (String) -> Void
    ) async throws -> Completion {
        var text = ""
        var finishReason: FinishReason = .other("no_completed")
        var toolCalls: [ToolCall] = []
        var usage: Usage?

        for try await event in stream {
            switch event {
            case .textDelta(let delta):
                text += delta
                onTextChanged(text)
            case .completed(let reason, let calls, let turnUsage):
                finishReason = reason
                toolCalls = calls
                usage = turnUsage
            }
        }
        return Completion(text: text, finishReason: finishReason, toolCalls: toolCalls, usage: usage)
    }
}

import Foundation
import Kernel

/// LLMイベント列を1回分の確定応答へ畳み込み、本文deltaだけを逐次UIへ通知する。
@MainActor
enum ChatCompletionStreamConsumer {
    // Completionだけではthrow時にheaders/出力の到着時点が失われる。本文やErrorを別の
    // wrapperへ詰め直さず、同じ時計で観測した小さなsnapshotだけを呼出元へ渡す。
    struct Progress {
        var responseStartedAt: TimeInterval?
        var firstOutputAt: TimeInterval?
        var firstTextDeltaAt: TimeInterval?
        var receivedCompletion = false
    }

    struct Completion {
        let text: String
        let finishReason: FinishReason
        let toolCalls: [ToolCall]
        let usage: Usage?
        let responseStartedAt: TimeInterval?
        let firstOutputAt: TimeInterval?
        let firstTextDeltaAt: TimeInterval?
        let completedAt: TimeInterval
    }

    static func consume(
        _ stream: AsyncThrowingStream<LLMEvent, Error>,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        onProgress: (Progress) -> Void = { _ in },
        onTextChanged: (String) -> Void
    ) async throws -> Completion {
        var text = ""
        var finishReason: FinishReason?
        var toolCalls: [ToolCall] = []
        var usage: Usage?
        var responseStartedAt: TimeInterval?
        var firstOutputAt: TimeInterval?
        var firstTextDeltaAt: TimeInterval?

        for try await event in stream {
            switch event {
            case .responseStarted:
                if responseStartedAt == nil { responseStartedAt = now() }
            case .outputStarted:
                if firstOutputAt == nil { firstOutputAt = now() }
            case .textDelta(let delta):
                if firstTextDeltaAt == nil, !delta.isEmpty {
                    let timestamp = now()
                    firstTextDeltaAt = timestamp
                    if firstOutputAt == nil { firstOutputAt = timestamp }
                }
                text += delta
                onTextChanged(text)
            case .completed(let reason, let calls, let turnUsage):
                finishReason = reason
                toolCalls = calls
                usage = turnUsage
            }
            onProgress(Progress(
                responseStartedAt: responseStartedAt,
                firstOutputAt: firstOutputAt,
                firstTextDeltaAt: firstTextDeltaAt,
                receivedCompletion: finishReason != nil
            ))
        }
        // 中立LLMClient契約のcompletedを受けていないEOFは未確定。adapter側の取りこぼしも
        // 成功へ変換せず、onTextChangedで表示済みの部分本文を残して失敗経路へ返す。
        // consumer取消による正常終了は通信欠落と区別し、既存のエラー非表示経路を保つ。
        try Task.checkCancellation()
        guard let finishReason else {
            throw LLMClientError.responseError("LLM stream ended before completed event")
        }
        return Completion(
            text: text,
            finishReason: finishReason,
            toolCalls: toolCalls,
            usage: usage,
            responseStartedAt: responseStartedAt,
            firstOutputAt: firstOutputAt,
            firstTextDeltaAt: firstTextDeltaAt,
            completedAt: now()
        )
    }
}

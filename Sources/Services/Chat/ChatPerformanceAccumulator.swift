import Foundation
import Kernel

/// 1ユーザー発話中に発生する複数LLMリクエストの計測値を、表示する最終assistantターンへ集約する。
final class ChatPerformanceAccumulator {
    private let turnStartedAt: TimeInterval
    private var firstModelResponseAt: TimeInterval?
    private var latestRequestTimeToFirstTokenSeconds: TimeInterval?
    private var generationSeconds = 0.0
    private var completionTokens = 0
    private var requestCount = 0

    init(turnStartedAt: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.turnStartedAt = turnStartedAt
    }

    func record(
        requestStartedAt: TimeInterval,
        firstOutputAt: TimeInterval?,
        completedAt: TimeInterval,
        usage: Usage?
    ) {
        requestCount += 1
        if firstModelResponseAt == nil, let firstOutputAt {
            firstModelResponseAt = firstOutputAt
        }
        if let firstOutputAt {
            // request単位のTTFT。複数request時はUIでは表示せず、各generationの値はOTelへ送る。
            latestRequestTimeToFirstTokenSeconds = max(0, firstOutputAt - requestStartedAt)
        }

        // text/tool-callのどちらも最初の出力からcompletionまでを生成区間として集計する。
        // 出力開始イベントが無い互換クライアントだけrequest開始へ保守的にフォールバックする。
        let generationStartedAt = firstOutputAt ?? requestStartedAt
        generationSeconds += max(0, completedAt - generationStartedAt)
        completionTokens += usage?.completionTokens ?? 0
    }

    var metrics: ChatPerformanceMetrics? {
        guard requestCount > 0 else { return nil }
        return ChatPerformanceMetrics(
            firstResponseMilliseconds: firstModelResponseAt.map { max(0, $0 - turnStartedAt) * 1_000 },
            timeToFirstTokenMilliseconds: latestRequestTimeToFirstTokenSeconds.map { $0 * 1_000 },
            generationMilliseconds: generationSeconds * 1_000,
            completionTokens: completionTokens,
            requestCount: requestCount
        )
    }
}

// 履歴カードの「保存表示は見せるが、現在状態の確認完了までは触らせない」操作ゲート。
import Observation
import Kernel
import Services

@MainActor
@Observable
final class HistoricalCardRevalidationGate {
    private(set) var state: HistoricalRevalidationState = .notRequired
    private(set) var toolResult: JSONValue?
    private var armed = false
    private var timeoutTask: Task<Void, Never>?

    func begin(with result: JSONValue) {
        state = state.applying(.begin)
        toolResult = HistoricalRevalidation.marking(result)
    }

    /// result handler が配送直後にtools/callし得るため、sendToolResultより前に呼ぶ。
    func arm() {
        armed = true
    }

    func shouldObserveToolCall() -> Bool {
        armed && state == .waiting
    }

    func observationPredicate() -> @Sendable () async -> Bool {
        { [weak self] in await self?.shouldObserveToolCall() ?? false }
    }

    func startTimeout() {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.state == .waiting else { return }
            self.state = self.state.applying(.timedOut)
        }
    }

    func complete(succeeded: Bool) {
        guard armed, state == .waiting else { return }
        timeoutTask?.cancel()
        state = state.applying(.toolCallCompleted(succeeded: succeeded))
    }

    /// HTML取得/session構築の失敗はtimer開始前にも起きる。spinnerを残さず即fail closedにする。
    func failBuildIfWaiting() {
        guard state == .waiting else { return }
        state = state.applying(.toolCallCompleted(succeeded: false))
    }

    func retry(using session: AppsBridgeSession?) {
        guard let session, let toolResult else { return }
        timeoutTask?.cancel()
        armed = true
        state = state.applying(.begin)
        Task { [weak self] in
            await session.sendToolResult(toolResult)
            await MainActor.run { self?.startTimeout() }
        }
    }

    func cancel() {
        timeoutTask?.cancel()
    }
}

extension InlineCardHost {
    func sendInitialPayload(card: CardEmbed, session: AppsBridgeSession) async {
        await session.sendToolInput(arguments: card.arguments ?? .object([:]))
        if let historicalToolResult = historicalRevalidation.toolResult {
            historicalRevalidation.arm()
            await session.sendToolResult(historicalToolResult)
            historicalRevalidation.startTimeout()
        } else {
            await session.sendToolResult(card.structuredContent ?? .null)
        }
    }
}

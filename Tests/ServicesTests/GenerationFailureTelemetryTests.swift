import Foundation
import Testing

@testable import Kernel
@testable import Services

@MainActor
@Suite(.serialized)
struct GenerationFailureTelemetryTests {
    // 成功fixtureだけでは失敗前のprogressを捨てる退行を検出できない。同じ-1005を
    // headers前/headers後/本文後で流し、分類が同じでも段階が区別されることを保証する。
    @Test(arguments: [0, 1, 2, 3, 4])
    func connectionLossRetainsClassificationAndObservedStage(_ milestone: Int) async throws {
        let events: [[LLMEvent]] = [
            [], [.responseStarted], [.responseStarted, .outputStarted],
            [.responseStarted, .textDelta("partial")],
            [.responseStarted, .textDelta("partial"), .completed(.stop, [], nil)]
        ]
        let telemetry = FailureTelemetryRecorder()
        let viewModel = ChatViewModel(
            llm: FailingGenerationClient(events: events[milestone], failure: URLError(.networkConnectionLost)),
            toolExecutor: StubToolExecutor(), tools: [], model: "fixture", systemPrompt: nil,
            telemetry: telemetry
        )
        await viewModel.send("failure observation")
        let error = try #require(telemetry.fields("llm.generation.error"))
        let started = try #require(telemetry.fields("llm.generation.started"))
        #expect(error["error.domain"] == NSURLErrorDomain)
        #expect(error["error.code"] == "-1005")
        #expect(error["error.type"] == "\(NSURLErrorDomain):-1005")
        #expect(error["llm.generation.failure_stage"] == [
            "awaiting_response", "awaiting_output", "streaming_output", "streaming_output", "after_completion"
        ][milestone])
        #expect(error["generation_id"] == started["generation_id"])
        #expect(error["turn_id"] == started["turn_id"])
        #expect(telemetry.fields("llm.generation.finished") == nil)
        #expect(Int(error["duration_ms"] ?? "") != nil)
        #expect((error["llm.generation.response_headers_ms"] != nil) == (milestone >= 1))
        #expect((error["llm.generation.ttft_ms"] != nil) == (milestone >= 2))
        #expect((error["llm.generation.time_to_first_text_ms"] != nil) == (milestone >= 3))
        #expect(viewModel.turns.last?.text == (milestone >= 3 ? "partial" : ""))
        #expect(viewModel.errorMessage != nil)
    }

    @Test func failureTimingUsesTheSameMonotonicMilestonesAndOmitsUnobservedValues() {
        let fields = GenerationFailureTelemetry.fields(
            error: URLError(.timedOut), requestStartedAt: 10, failedAt: 15,
            progress: .init(responseStartedAt: 11, firstOutputAt: 12, firstTextDeltaAt: 13)
        )
        #expect(fields["error.code"] == "-1001")
        #expect(fields["duration_ms"] == "5000")
        #expect(fields["llm.generation.response_headers_ms"] == "1000")
        #expect(fields["llm.generation.ttft_ms"] == "2000")
        #expect(fields["llm.generation.headers_to_first_output_ms"] == "1000")
        #expect(fields["llm.generation.time_to_first_text_ms"] == "3000")
        let unobserved = GenerationFailureTelemetry.fields(
            error: URLError(.networkConnectionLost), requestStartedAt: 10, failedAt: 12, progress: .init()
        )
        #expect(unobserved["llm.generation.ttft_ms"] == nil)
        #expect(unobserved["llm.generation.response_headers_ms"] == nil)
        // NSError.userInfoはURL/headers等を含み得る。分類のために展開する必要はない。
        #expect(unobserved[NSURLErrorFailingURLErrorKey] == nil)
    }

    @Test func httpFailureAndCancellationRemainDistinctWithoutChangingTheUI() async throws {
        for (failure, expectedType, expectedStage) in [
            (LLMClientError.httpError(statusCode: 530, body: "fixture") as Error, "530", "http_error"),
            (CancellationError() as Error, "cancelled", "awaiting_response")
        ] {
            let telemetry = FailureTelemetryRecorder()
            let viewModel = ChatViewModel(
                llm: FailingGenerationClient(events: [], failure: failure),
                toolExecutor: StubToolExecutor(), tools: [], model: "fixture", systemPrompt: nil,
                telemetry: telemetry
            )
            await viewModel.send("failure observation")
            let fields = try #require(telemetry.fields("llm.generation.error"))
            #expect(fields["error.type"] == expectedType)
            #expect(fields["llm.generation.failure_stage"] == expectedStage)
            #expect((viewModel.errorMessage == nil) == (failure is CancellationError))
            if failure is CancellationError {
                #expect(fields["error"] == "cancelled")
                #expect(fields["http.response.status_code"] == nil)
            } else {
                #expect(fields["http.response.status_code"] == "530")
            }
        }
    }
}

// 明示的なイベント後にthrowすることで、ネットワークfixtureのタイミング依存を分類検証へ持ち込まない。
private struct FailingGenerationClient: LLMClient, @unchecked Sendable {
    let events: [LLMEvent]
    let failure: Error

    func stream(_ request: ChatCompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish(throwing: failure)
        }
    }
}

private final class FailureTelemetryRecorder: TelemetryPort, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String: [String: String]] = [:]

    func event(_ name: String, fields: [String: String], level: TelemetryLevel) {
        lock.lock(); defer { lock.unlock() }
        events[name] = fields
    }

    func fields(_ name: String) -> [String: String]? {
        lock.lock(); defer { lock.unlock() }
        return events[name]
    }
}

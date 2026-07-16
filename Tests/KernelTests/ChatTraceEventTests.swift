// ChatTraceEvent(Kernel/Tracing)の Codable round-trip テスト。設計 03 §3。
// TraceSink の実装(OSLogTraceSink)は Services 側なので直接テストしない
// (OSLog 出力の検証は unified log を読む必要があり swift-testing の範囲を超える)。
// ここでは「イベント自体が失われずシリアライズできる」ことだけを担保する
// (将来 ChatStore 経由の永続化 Sink を足すときにここが効く)。
import Foundation
import Testing
@testable import Kernel

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
}

@Test("turnStarted は round-trip する")
func chatTraceEventRoundTripTurnStarted() throws {
    let event = ChatTraceEvent.turnStarted(chatId: "chat-1", turnId: "turn-1", model: "gpt-5-mini")
    #expect(try roundTrip(event) == event)
}

@Test("llmCompleted は usage あり/なしどちらも round-trip する")
func chatTraceEventRoundTripLLMCompleted() throws {
    let withUsage = ChatTraceEvent.llmCompleted(
        turnId: "turn-1", finishReason: "tool_calls",
        usage: Usage(promptTokens: 10, completionTokens: 5, totalTokens: 15))
    #expect(try roundTrip(withUsage) == withUsage)

    let withoutUsage = ChatTraceEvent.llmCompleted(turnId: "turn-1", finishReason: "stop", usage: nil)
    #expect(try roundTrip(withoutUsage) == withoutUsage)
}

@Test("toolCallStarted は arguments(JSONValue)を含めて round-trip する")
func chatTraceEventRoundTripToolCallStarted() throws {
    let event = ChatTraceEvent.toolCallStarted(
        turnId: "turn-1", callId: "call-1", name: "list-todos",
        arguments: .object(["calendarId": .string("primary")]))
    #expect(try roundTrip(event) == event)
}

@Test("toolCallFinished は round-trip する")
func chatTraceEventRoundTripToolCallFinished() throws {
    let event = ChatTraceEvent.toolCallFinished(
        turnId: "turn-1", callId: "call-1", isError: false, resultBytes: 1024, durationMs: 42)
    #expect(try roundTrip(event) == event)
}

@Test("turnSettled は round-trip する")
func chatTraceEventRoundTripTurnSettled() throws {
    let event = ChatTraceEvent.turnSettled(
        turnId: "turn-1", iterations: 2,
        cumulativeUsage: Usage(promptTokens: 50, completionTokens: 11, totalTokens: 61))
    #expect(try roundTrip(event) == event)
}

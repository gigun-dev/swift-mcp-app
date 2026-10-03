import Foundation
import Testing

@testable import Kernel
@testable import Services

private final class PerformanceTelemetrySpy: TelemetryPort, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [(String, [String: String])] = []

    func event(_ name: String, fields: [String: String], level: TelemetryLevel) {
        lock.withLock { records.append((name, fields)) }
    }

    func fields(for name: String) -> [String: String]? {
        lock.withLock { records.first(where: { $0.0 == name })?.1 }
    }
}

@MainActor
@Test("最初の本文deltaとcompletionの時刻を記録する")
func completionConsumerRecordsTiming() async throws {
    let stream = AsyncThrowingStream<LLMEvent, Error> { continuation in
        continuation.yield(.responseStarted)
        continuation.yield(.textDelta("応答"))
        continuation.yield(.textDelta("です"))
        continuation.yield(.completed(.stop, [], Usage(promptTokens: 10, completionTokens: 4)))
        continuation.finish()
    }
    var times = [10.0, 10.2, 11.0].makeIterator()

    let completion = try await ChatCompletionStreamConsumer.consume(
        stream,
        now: { times.next()! },
        onTextChanged: { _ in }
    )

    #expect(completion.responseStartedAt == 10.0)
    #expect(completion.firstTextDeltaAt == 10.2)
    #expect(completion.firstOutputAt == 10.2)
    #expect(completion.completedAt == 11.0)
}

@MainActor
@Test("tool call deltaも最初のモデル出力として記録する")
func completionConsumerRecordsToolOutputTiming() async throws {
    let stream = AsyncThrowingStream<LLMEvent, Error> { continuation in
        continuation.yield(.responseStarted)
        continuation.yield(.outputStarted)
        continuation.yield(.completed(.toolCalls, [], nil))
        continuation.finish()
    }
    var times = [4.0, 4.2, 5.0].makeIterator()
    let completion = try await ChatCompletionStreamConsumer.consume(
        stream,
        now: { times.next()! },
        onTextChanged: { _ in }
    )

    #expect(completion.responseStartedAt == 4.0)
    #expect(completion.firstOutputAt == 4.2)
    #expect(completion.firstTextDeltaAt == nil)
    #expect(completion.completedAt == 5.0)
}

@Test("複数LLMラウンドではbubble用の単一TTFTを返さない")
func performanceAccumulatorAggregatesToolRounds() throws {
    let accumulator = ChatPerformanceAccumulator(turnStartedAt: 9.5)
    accumulator.record(
        requestStartedAt: 10,
        firstOutputAt: 10.5,
        completedAt: 11,
        usage: Usage(promptTokens: 20, completionTokens: 3)
    )
    accumulator.record(
        requestStartedAt: 13,
        firstOutputAt: 13.2,
        completedAt: 14.2,
        usage: Usage(promptTokens: 30, completionTokens: 7)
    )

    let metrics = try #require(accumulator.metrics)
    // first model responseは最初のtool-call delta。request間のMCP実行時間は含まない。
    #expect(abs((metrics.firstResponseMilliseconds ?? 0) - 1_000) < 0.001)
    #expect(abs((metrics.timeToFirstTokenMilliseconds ?? 0) - 200) < 0.001)
    #expect(metrics.singleRequestTTFTMilliseconds == nil)
    #expect(abs(metrics.generationMilliseconds - 1_500) < 0.001)
    #expect(metrics.completionTokens == 10)
    #expect(metrics.requestCount == 2)
    #expect(abs((metrics.tokensPerSecond ?? 0) - (10.0 / 1.5)) < 0.001)
    #expect(abs((metrics.millisecondsPerToken ?? 0) - 150) < 0.001)
}

@Test("最初のモデル応答はturn先頭、内部TTFTは最新requestの値を保持する")
func performanceAccumulatorSeparatesTurnResponseFromRequestTTFT() throws {
    let accumulator = ChatPerformanceAccumulator(turnStartedAt: 9)
    accumulator.record(
        requestStartedAt: 10,
        firstOutputAt: 10.8,
        completedAt: 11,
        usage: Usage(promptTokens: 20, completionTokens: 3)
    )
    accumulator.record(
        requestStartedAt: 15,
        firstOutputAt: 15.15,
        completedAt: 16,
        usage: Usage(promptTokens: 30, completionTokens: 7)
    )

    let metrics = try #require(accumulator.metrics)
    // turn-level値は最初の出力を維持し、request単位TTFTとは別にする。
    #expect(abs((metrics.firstResponseMilliseconds ?? 0) - 1_800) < 0.001)
    #expect(abs((metrics.timeToFirstTokenMilliseconds ?? 0) - 150) < 0.001)
}

@Test("本文もtool出力も無いrequestはfirst model responseを作らない")
func performanceAccumulatorDoesNotInventVisibleResponse() throws {
    let accumulator = ChatPerformanceAccumulator(turnStartedAt: 1)
    accumulator.record(
        requestStartedAt: 2,
        firstOutputAt: nil,
        completedAt: 3,
        usage: nil
    )

    let metrics = try #require(accumulator.metrics)
    #expect(metrics.firstResponseMilliseconds == nil)
    #expect(metrics.timeToFirstTokenMilliseconds == nil)
}

@Test("単一LLM requestのときだけbubble用TTFTを返す")
func performanceMetricExposesTTFTForSingleRequest() throws {
    let accumulator = ChatPerformanceAccumulator(turnStartedAt: 1)
    accumulator.record(
        requestStartedAt: 2,
        firstOutputAt: 2.25,
        completedAt: 3,
        usage: Usage(promptTokens: 1, completionTokens: 2)
    )
    let metrics = try #require(accumulator.metrics)
    #expect(metrics.singleRequestTTFTMilliseconds == 250)
}

@MainActor
@Test("generation単位のTTFTをtelemetryへ記録する")
func generationTTFTIsRecordedInTelemetry() async throws {
    let telemetry = PerformanceTelemetrySpy()
    let viewModel = ChatViewModel(
        llm: ScriptedLLMClient(scripts: [
            [.textDelta("回答"), .completed(.stop, [], Usage(promptTokens: 1, completionTokens: 1))]
        ]),
        toolExecutor: StubToolExecutor(),
        tools: [],
        model: "m",
        systemPrompt: nil,
        telemetry: telemetry
    )

    await viewModel.send("質問")

    let fields = try #require(telemetry.fields(for: "llm.generation.finished"))
    let ttftText = try #require(fields["llm.generation.ttft_ms"])
    let ttft = try #require(Int(ttftText))
    #expect(ttft >= 0)
    #expect(fields["llm.generation.request_index"] == "1")
    #expect(fields["llm.generation.phase"] == "initial_decision_or_answer")
    #expect(fields["llm.generation.response_kind"] == "text")
}

@Test("LLM request診断は本文を返さずsystem・messages・tool schemaのサイズだけを返す")
func requestPayloadMetricsContainOnlySizes() throws {
    let tools = [
        ToolDefinition(function: .init(
            name: "calendar",
            description: "予定を読む",
            parameters: .object(["type": .string("object")])
        ))
    ]
    let request = ChatCompletionRequest(
        model: "m",
        messages: [
            ChatMessage(role: .system, content: "system"),
            ChatMessage(role: .user, content: "秘密の本文")
        ],
        tools: tools,
        stream: true
    )
    let encoded = try JSONEncoder().encode(request)
    let encodedTools = try JSONEncoder().encode(tools)
    let encodedMessages = try JSONEncoder().encode(request.messages)
    let encodedSystem = try JSONEncoder().encode([request.messages[0]])
    let encodedConversation = try JSONEncoder().encode([request.messages[1]])
    let encodedSchemas = try JSONEncoder().encode(tools.map(\.function.parameters))
    let metrics = try OpenAICompatClient.payloadMetrics(for: request, encodedBody: encoded)

    #expect(metrics.messageCount == 2)
    #expect(metrics.systemPromptUTF8Bytes == "system".utf8.count)
    #expect(metrics.systemMessagesJSONBytes == encodedSystem.count)
    #expect(metrics.conversationMessagesJSONBytes == encodedConversation.count)
    #expect(metrics.messagesJSONBytes == encodedMessages.count)
    #expect(metrics.toolCount == 1)
    #expect(metrics.toolsJSONBytes == encodedTools.count)
    #expect(metrics.toolSchemasJSONBytes == encodedSchemas.count)
    #expect(metrics.estimatedToolSchemaTokens == (encodedSchemas.count + 3) / 4)
    #expect(metrics.requestJSONBytes == encoded.count)
}

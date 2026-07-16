// Kernel/LLMProtocol の round-trip・蓄積ロジック・visibility 判定テスト(P3 T1)。
//
// テスト方針(CLAUDE.md「テスト = What」): SSE チャンクの fixture JSON は実際の
// OpenAI streaming-events リファレンスに出てくる形(docs/design/02-chat-llm.md §2 出典)に
// 忠実にする。特に「usage は choices:[] の追加チャンクで届く」事実を明示ケースにする
// (パーサが choices[0] を無条件に読もうとして落ちないことの回帰防止)。
import Foundation
import Testing
@testable import Kernel

private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(json.utf8))
}

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
}

// MARK: - ChatCompletionRequest / ChatMessage / ToolDefinition

@Test("ChatCompletionRequest は tools・stream_options 込みで round-trip する")
func chatCompletionRequestRoundTrip() throws {
    let request = ChatCompletionRequest(
        model: "gpt-4o-mini",
        messages: [
            ChatMessage(role: .system, content: "You are a helpful assistant."),
            ChatMessage(role: .user, content: "今日の予定を教えて"),
        ],
        tools: [
            ToolDefinition(function: .init(
                name: "list-todos",
                description: "未完了タスク一覧を返す",
                parameters: ["type": "object", "properties": [:]]
            )),
        ],
        stream: true,
        temperature: 0.7,
        streamOptions: .init(includeUsage: true)
    )
    #expect(try roundTrip(request) == request)
}

@Test("ChatCompletionRequest の JSON キーは OpenAI 互換の snake_case")
func chatCompletionRequestWireKeys() throws {
    let request = ChatCompletionRequest(
        model: "gpt-4o-mini",
        messages: [],
        stream: true,
        streamOptions: .init(includeUsage: true)
    )
    let data = try JSONEncoder().encode(request)
    let json = try #require(String(data: data, encoding: .utf8))
    #expect(json.contains("\"stream_options\""))
    #expect(json.contains("\"include_usage\""))
}

@Test("ChatMessage: assistant が tool_calls のみのとき content は null で round-trip する")
func chatMessageAssistantToolCallsOnly() throws {
    let message = ChatMessage(
        role: .assistant,
        content: nil,
        toolCalls: [ToolCall(id: "call_1", function: .init(name: "list-todos", arguments: "{}"))]
    )
    #expect(try roundTrip(message) == message)

    let toolResultMessage = ChatMessage(
        role: .tool,
        content: "{\"todos\":[]}",
        toolCallId: "call_1"
    )
    #expect(try roundTrip(toolResultMessage) == toolResultMessage)
}

// MARK: - Usage / FinishReason

@Test("Usage は total_tokens 省略でも round-trip する")
func usageRoundTripWithoutTotal() throws {
    let json = #"{"prompt_tokens":120,"completion_tokens":40}"#
    let usage = try decode(Usage.self, json)
    #expect(usage.promptTokens == 120)
    #expect(usage.completionTokens == 40)
    #expect(usage.totalTokens == nil)
}

@Test("FinishReason は snake_case ワイヤ値を読み替える")
func finishReasonWireMapping() throws {
    #expect(try decode(FinishReason.self, "\"stop\"") == .stop)
    #expect(try decode(FinishReason.self, "\"tool_calls\"") == .toolCalls)
    #expect(try decode(FinishReason.self, "\"length\"") == .length)
    #expect(try decode(FinishReason.self, "\"content_filter\"") == .contentFilter)
    #expect(try decode(FinishReason.self, "\"something_new\"") == .other("something_new"))
    #expect(try roundTrip(FinishReason.toolCalls) == .toolCalls)
}

// MARK: - ChatCompletionChunk(SSE)

@Test("ChatCompletionChunk: 本文 content delta をデコードできる")
func chunkContentDelta() throws {
    let json = #"""
    {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"role":"assistant","content":"こん"},"finish_reason":null}]}
    """#
    let chunk = try decode(ChatCompletionChunk.self, json)
    #expect(chunk.choices.count == 1)
    #expect(chunk.choices[0].delta.content == "こん")
    #expect(chunk.choices[0].finishReason == nil)
    #expect(try roundTrip(chunk) == chunk)
}

@Test("ChatCompletionChunk: tool_calls 初回 delta は id と function.name を持つ")
func chunkToolCallFirstDelta() throws {
    let json = #"""
    {"id":"chatcmpl-2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_abc","function":{"name":"list-todos","arguments":""}}]},"finish_reason":null}]}
    """#
    let chunk = try decode(ChatCompletionChunk.self, json)
    let delta = try #require(chunk.choices[0].delta.toolCalls?.first)
    #expect(delta.id == "call_abc")
    #expect(delta.function?.name == "list-todos")
    #expect(delta.function?.arguments == "")
}

@Test("ChatCompletionChunk: tool_calls 継続 delta は arguments の断片のみを持つ(id/name 無し)")
func chunkToolCallContinuationDelta() throws {
    let json = #"""
    {"id":"chatcmpl-2","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"limit\""}}]},"finish_reason":null}]}
    """#
    let chunk = try decode(ChatCompletionChunk.self, json)
    let delta = try #require(chunk.choices[0].delta.toolCalls?.first)
    #expect(delta.id == nil)
    #expect(delta.function?.name == nil)
    #expect(delta.function?.arguments == "{\"limit\"")
}

@Test("ChatCompletionChunk: finish_reason チャンクをデコードできる")
func chunkFinishReason() throws {
    let json = #"""
    {"id":"chatcmpl-2","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}
    """#
    let chunk = try decode(ChatCompletionChunk.self, json)
    #expect(chunk.choices[0].finishReason == .toolCalls)
}

@Test("ChatCompletionChunk: usage-only チャンクは choices が空配列でも壊れずデコードできる")
func chunkUsageOnlyEmptyChoices() throws {
    // §2 出典の裏取りケース: stream_options.include_usage:true のとき、finish_reason
    // チャンクの後にこの形の追加チャンクが届く。choices[0] を仮定した実装だと
    // ここで添字アウトオブレンジになる——という回帰を防ぐためのテスト。
    let json = #"""
    {"id":"chatcmpl-2","choices":[],"usage":{"prompt_tokens":50,"completion_tokens":12,"total_tokens":62}}
    """#
    let chunk = try decode(ChatCompletionChunk.self, json)
    #expect(chunk.choices.isEmpty)
    #expect(chunk.usage?.promptTokens == 50)
    #expect(chunk.usage?.totalTokens == 62)
    #expect(try roundTrip(chunk) == chunk)
}

// MARK: - ToolCallAccumulator

@Test("ToolCallAccumulator: 単一 tool_call の分割 delta を arguments 連結で確定させる")
func accumulatorSingleToolCallFragments() {
    var accumulator = ToolCallAccumulator()
    accumulator.accumulate([
        ToolCallDelta(index: 0, id: "call_1", function: .init(name: "list-todos", arguments: "")),
    ])
    accumulator.accumulate([
        ToolCallDelta(index: 0, function: .init(arguments: "{\"limit\":")),
    ])
    accumulator.accumulate([
        ToolCallDelta(index: 0, function: .init(arguments: "5}")),
    ])
    let result = accumulator.finalize()
    #expect(result == [ToolCall(id: "call_1", function: .init(name: "list-todos", arguments: "{\"limit\":5}"))])
}

@Test("ToolCallAccumulator: 複数 index(複数 tool_call)を index 昇順で確定させる")
func accumulatorMultipleToolCalls() {
    var accumulator = ToolCallAccumulator()
    // わざと index=1 を先に流す(プロバイダ・ネットワークの並び揺れへの耐性を確認)。
    accumulator.accumulate([
        ToolCallDelta(index: 1, id: "call_2", function: .init(name: "list-events", arguments: "{}")),
    ])
    accumulator.accumulate([
        ToolCallDelta(index: 0, id: "call_1", function: .init(name: "list-todos", arguments: "")),
    ])
    accumulator.accumulate([
        ToolCallDelta(index: 0, function: .init(arguments: "{}")),
    ])
    let result = accumulator.finalize()
    #expect(result.map(\.id) == ["call_1", "call_2"])
    #expect(result[0].function.name == "list-todos")
    #expect(result[0].function.arguments == "{}")
    #expect(result[1].function.name == "list-events")
    #expect(result[1].function.arguments == "{}")
}

@Test("ToolCallAccumulator: 1チャンクに複数 index が混在しても分配される")
func accumulatorMixedIndicesInSingleChunk() {
    var accumulator = ToolCallAccumulator()
    accumulator.accumulate([
        ToolCallDelta(index: 0, id: "call_a", function: .init(name: "a", arguments: "1")),
        ToolCallDelta(index: 1, id: "call_b", function: .init(name: "b", arguments: "2")),
    ])
    let result = accumulator.finalize()
    #expect(result.count == 2)
    #expect(result[0].function.arguments == "1")
    #expect(result[1].function.arguments == "2")
}

// MARK: - ToolVisibility

@Test("isModelVisible: visibility 省略時は既定 [\"model\",\"app\"] 扱いで true")
func isModelVisibleDefaultsToTrue() {
    #expect(isModelVisible(uiMeta: nil) == true)
    #expect(isModelVisible(uiMeta: ["resourceUri": "ui://todos/list"]) == true)
}

@Test("isModelVisible: [\"model\",\"app\"] は true・[\"app\"] のみは false・[\"model\"] のみは true")
func isModelVisibleExplicitArrays() {
    #expect(isModelVisible(uiMeta: ["visibility": ["model", "app"]]) == true)
    #expect(isModelVisible(uiMeta: ["visibility": ["app"]]) == false)
    #expect(isModelVisible(uiMeta: ["visibility": ["model"]]) == true)
}

@Test("isAppCallable: visibility 省略時は既定で true・[\"app\"] のみは true・[\"model\"] のみは false")
func isAppCallableVariants() {
    #expect(isAppCallable(uiMeta: nil) == true)
    #expect(isAppCallable(uiMeta: ["visibility": ["model", "app"]]) == true)
    #expect(isAppCallable(uiMeta: ["visibility": ["app"]]) == true)
    #expect(isAppCallable(uiMeta: ["visibility": ["model"]]) == false)
}

import Foundation
import Testing

@testable import Kernel
@testable import Services

// ネットワーク推論を混ぜると課金・queue・回線差で縮約そのものの効果が見えなくなる。
// 実tool-use loopの二度目のrequestを捕まえ、両adapterの送信bodyサイズを比べる。
// 時間はローカルstubの診断値だけ。3秒の製品目標を合否判定する値にはしない。
@Suite(.serialized)
struct MCPResultPayloadBenchmarkTests {
    @MainActor
    @Test("縮約は両APIの送信量を減らし完全なMCP結果をカードと履歴に保つ", arguments: [1_000, 100_000])
    func payloadBaseline(repetitions: Int) async throws {
        let text = "現在の待ち時間は20分です。"
        let result: JSONValue = .object([
            "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            "structuredContent": .object(["largePayload": .string(String(repeating: "history", count: repetitions))]),
            "isError": .bool(false),
            "_meta": .object(["ui": .object(["resourceUri": .string("ui://wait/chart")])])
        ])
        let encoder = JSONEncoder()
        let full = try encoder.encode(result)
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.toolCalls, [ToolCall(id: "c1", function: .init(name: "wait", arguments: "{}"))], nil)],
            [.textDelta("確認しました"), .completed(.stop, [], nil)]
        ])
        let viewModel = ChatViewModel(
            llm: llm, toolExecutor: StubToolExecutor(results: ["wait": result]), tools: [],
            model: "fixture-model", systemPrompt: nil, uiResourceURIs: ["wait": "ui://wait/chart"])
        let start = ContinuousClock.now
        await viewModel.send("待ち時間")
        let localDuration = start.duration(to: .now)
        #expect(llm.receivedRequests.count == 2)
        let request = try #require(llm.receivedRequests.last)
        let message = try #require(request.messages.first { $0.role == .tool })
        #expect(message.content == text)
        let card = try #require(viewModel.turns.flatMap(\.cards).first)
        #expect(card.structuredContent == result)
        let step = try #require(viewModel.turns.flatMap(\.toolSteps).first)
        let saved = try #require(step.resultJSON)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(saved.utf8)) == result)

        // requestの他フィールドを固定し、旧来の完全JSON再入力だけを比較側へ戻す。
        // payloadの順序には依存せず、同じencoder/adapterへ両側を通す。
        var uncompressed = request
        let index = try #require(uncompressed.messages.firstIndex { $0.role == .tool })
        uncompressed.messages[index].content = String(bytes: full, encoding: .utf8)
        let chatSmall = try encoder.encode(request).count
        let chatFull = try encoder.encode(uncompressed).count
        let responsesSmall = try encoder.encode(OpenAIResponsesClient.responsesBody(from: request)).count
        let responsesFull = try encoder.encode(OpenAIResponsesClient.responsesBody(from: uncompressed)).count
        #expect(chatSmall < chatFull)
        #expect(responsesSmall < responsesFull)
        let outputs = OpenAIResponsesClient.responsesBody(from: request)["input"]?.arrayValue
        #expect(outputs?.first { $0["type"]?.stringValue == "function_call_output" }?["output"]?.stringValue == text)
        print("MCP_PAYLOAD_BASELINE repetitions=\(repetitions) full_result_bytes=\(full.count) llm_text_bytes=\(text.utf8.count) chat_full_bytes=\(chatFull) chat_text_bytes=\(chatSmall) responses_full_bytes=\(responsesFull) responses_text_bytes=\(responsesSmall) stub_turn=\(localDuration)")
    }

    @Test("エラーとtext不在の完全JSON fallbackは縮約の性能値へ混ぜない")
    func fallbackPreservesInformation() throws {
        // errorの詳細や非text結果を捨てた小さいrequestは成功の証拠にならない。
        // 正常textのfixtureと分離して既存fallback契約を確認する。
        for result: JSONValue in [
            .object([
                "isError": .bool(true),
                "content": .array([.object(["type": .string("text"), "text": .string("失敗")])]),
                "_meta": .object(["detail": .string("保持")])
            ]),
            .object(["structuredContent": .object(["value": .int(42)])])
        ] {
            let data = try JSONEncoder().encode(result)
            let full = try #require(String(bytes: data, encoding: .utf8))
            #expect(ToolCallRunner.llmContent(for: result, fallbackJSON: full) == full)
        }
    }
}

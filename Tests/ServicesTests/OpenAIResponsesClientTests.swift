import Foundation
import Testing

@testable import Kernel
@testable import Services

private final class ResponsesStubURLProtocol: URLProtocol {
    static var handler: (@Sendable (URLRequest) -> StubURLProtocol.Response)?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let result = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: result.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: result.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized) struct OpenAIResponsesClientTests {
    private struct Completion {
        let reason: FinishReason
        let calls: [ToolCall]
        let usage: Usage?
    }

    private func makeStubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ResponsesStubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeRequest() -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: "gpt-test",
            messages: [ChatMessage(role: .user, content: "hi")],
            stream: true
        )
    }

    private func sseBody(_ payloads: [String]) -> Data {
        Data(payloads.map { "data: \($0)\n\n" }.joined().utf8)
    }

    @Test func responsesURLはbaseとchatCompletionsから正規化される() throws {
        let base = try #require(URL(string: "https://api.openai.com/v1"))
        let chat = try #require(URL(string: "https://api.openai.com/v1/chat/completions"))
        #expect(OpenAIResponsesClient.responsesURL(from: base).absoluteString
            == "https://api.openai.com/v1/responses")
        #expect(OpenAIResponsesClient.responsesURL(from: chat).absoluteString
            == "https://api.openai.com/v1/responses")
    }

    @Test func responsesBodyは履歴とfunctionItemsをtypedItemsへ変換する() throws {
        let request = ChatCompletionRequest(
            model: "gpt-test",
            messages: [
                .init(role: .system, content: "system"),
                .init(role: .user, content: "待ち時間"),
                .init(role: .assistant, toolCalls: [
                    ToolCall(
                        id: "call_1",
                        function: .init(name: "attraction_wait", arguments: #"{"park":"land"}"#)
                    )
                ]),
                .init(role: .tool, content: #"{"wait":20}"#, toolCallId: "call_1")
            ],
            tools: [.init(function: .init(
                name: "attraction_wait",
                description: "wait",
                parameters: ["type": "object"]
            ))],
            stream: true,
            reasoningEffort: "low"
        )

        let body = OpenAIResponsesClient.responsesBody(from: request)
        #expect(body["instructions"]?.stringValue == "system")
        #expect(body["store"]?.boolValue == false)
        #expect(body["reasoning"]?["effort"]?.stringValue == "low")
        let input = try #require(body["input"]?.arrayValue)
        #expect(input.map { $0["type"]?.stringValue }
            == ["message", "function_call", "function_call_output"])
        #expect(input[1]["call_id"]?.stringValue == "call_1")
        let tool = try #require(body["tools"]?.arrayValue?.first)
        #expect(tool["name"]?.stringValue == "attraction_wait")
        #expect(tool["strict"]?.boolValue == false)
    }

    @Test func responsesStreamはfunctionCallとusageを既存イベントへ変換する() async throws {
        let added = #"{"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","#
            + #""id":"fc_1","call_id":"call_1","name":"attraction_wait","arguments":""}}"#
        let delta = #"{"type":"response.function_call_arguments.delta","output_index":0,"#
            + #""item_id":"fc_1","delta":"{\"park\":\"land\"}"}"#
        let done = #"{"type":"response.output_item.done","output_index":0,"item":{"type":"function_call","#
            + #""id":"fc_1","call_id":"call_1","name":"attraction_wait","#
            + #""arguments":"{\"park\":\"land\"}"}}"#
        let completed = #"{"type":"response.completed","response":{"usage":{"input_tokens":120,"#
            + #""output_tokens":8,"total_tokens":128,"input_tokens_details":{"cached_tokens":64}}}}"#
        let body = sseBody([added, delta, done, completed])
        ResponsesStubURLProtocol.handler = { request in
            #expect(request.url?.absoluteString == "https://api.openai.com/v1/responses")
            return .init(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: body)
        }
        let client = OpenAIResponsesClient(
            baseURL: URL(string: "https://api.openai.com/v1/chat/completions")!,
            apiKey: "test-key",
            urlSession: makeStubbedSession()
        )
        var events: [String] = []
        var completion: Completion?
        for try await event in client.stream(makeRequest()) {
            switch event {
            case .responseStarted: events.append("response")
            case .outputStarted: events.append("output")
            case .textDelta: events.append("text")
            case .completed(let reason, let calls, let usage):
                events.append("completed")
                completion = .init(reason: reason, calls: calls, usage: usage)
            }
        }
        #expect(events == ["response", "output", "completed"])
        #expect(completion?.reason == .toolCalls)
        #expect(completion?.calls.first?.id == "call_1")
        #expect(completion?.calls.first?.function.arguments == #"{"park":"land"}"#)
        #expect(completion?.usage?.promptTokensDetails?.cachedTokens == 64)
    }
}

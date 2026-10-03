import Foundation
import Kernel

/// OpenAI Responses API を既存の中立 `LLMClient` 契約へ載せるアダプタ。
/// ChatViewModel は履歴とMCP function toolsを従来どおり組み立て、この境界だけが
/// Chat Completions の messages/tool_calls を Responses の typed items へ変換する。
public struct OpenAIResponsesClient: LLMClient {
    private let endpoint: URL
    private let apiKey: String
    private let urlSession: URLSession

    public init(baseURL: URL, apiKey: String, urlSession: URLSession? = nil) {
        self.endpoint = Self.responsesURL(from: baseURL)
        self.apiKey = apiKey
        self.urlSession = urlSession ?? Self.defaultSession()
    }

    /// `/v1`、`/v1/chat/completions`、`/v1/responses` のどれを保存していても Responses へ正規化する。
    /// 独自 reverse proxy の prefix は保ち、末尾の既知API名だけを置き換える。
    public static func responsesURL(from baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        var path = components?.percentEncodedPath ?? baseURL.path
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        if path.hasSuffix("/responses") { return baseURL }
        if path.hasSuffix("/chat/completions") {
            path.removeLast("/chat/completions".count)
        }
        components?.percentEncodedPath = path.hasSuffix("/v1") ? path + "/responses" : path + "/responses"
        return components?.url ?? baseURL.appendingPathComponent("responses")
    }

    public func stream(_ request: ChatCompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await runStream(request, into: continuation)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runStream(
        _ chatRequest: ChatCompletionRequest,
        into continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        let body = Self.responsesBody(from: chatRequest)
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (bytes, response) = try await urlSession.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw LLMClientError.httpError(statusCode: http.statusCode, body: try await Self.collectBody(bytes))
        }
        continuation.yield(.responseStarted)
        try await consumeSSE(bytes, into: continuation)
    }

    /// Responses は `event:` と同じ type を JSON の `type` にも載せるため、共通の data parserだけで
    /// 解釈できる。function call arguments は delta を順に連結し、既存 ToolCall へ確定する。
    private func consumeSSE(
        _ bytes: URLSession.AsyncBytes,
        into continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        var parser = SSELineParser()
        var accumulator = ResponsesAccumulator()
        var lineBuffer: [UInt8] = []
        var completed = false

        func handle(_ payload: String) throws {
            guard !payload.isEmpty, payload != "[DONE]" else { return }
            let event = try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
            if try accumulator.handle(event, continuation: continuation) { completed = true }
        }

        for try await byte in bytes {
            guard byte != 0x0A else {
                if lineBuffer.last == 0x0D { lineBuffer.removeLast() }
                // swiftlint:disable:next optional_data_string_conversion
                let line = String(decoding: lineBuffer, as: UTF8.self)
                lineBuffer.removeAll(keepingCapacity: true)
                if let payload = parser.consume(line: line) { try handle(payload) }
                if completed { break }
                continue
            }
            lineBuffer.append(byte)
        }
        if !completed, !lineBuffer.isEmpty {
            if lineBuffer.last == 0x0D { lineBuffer.removeLast() }
            // swiftlint:disable:next optional_data_string_conversion
            let line = String(decoding: lineBuffer, as: UTF8.self)
            if let payload = parser.consume(line: line) { try handle(payload) }
        }
        if !completed, let payload = parser.flush() { try handle(payload) }
        guard completed else {
            throw LLMClientError.responseError("Responses stream ended before response.completed")
        }
        continuation.finish()
    }

    // 履歴role・tool item・optional設定をすべて写像する変換器なので、分岐数と長さを一体で読む。
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func responsesBody(from request: ChatCompletionRequest) -> JSONValue {
        let instructions = request.messages
            .filter { $0.role == .system }
            .compactMap(\.content)
            .joined(separator: "\n\n")
        var input: [JSONValue] = []
        for message in request.messages where message.role != .system {
            switch message.role {
            case .user, .assistant:
                if let content = message.content, !content.isEmpty {
                    input.append(.object([
                        "type": .string("message"),
                        "role": .string(message.role.rawValue),
                        "content": .string(content)
                    ]))
                }
                if message.role == .assistant {
                    for call in message.toolCalls ?? [] {
                        input.append(.object([
                            "type": .string("function_call"),
                            "call_id": .string(call.id),
                            "name": .string(call.function.name),
                            "arguments": .string(call.function.arguments)
                        ]))
                    }
                }
            case .tool:
                if let callID = message.toolCallId {
                    input.append(.object([
                        "type": .string("function_call_output"),
                        "call_id": .string(callID),
                        "output": .string(message.content ?? "")
                    ]))
                }
            case .system:
                break
            }
        }

        var object: [String: JSONValue] = [
            "model": .string(request.model),
            "input": .array(input),
            "stream": .bool(true),
            // 既存ホストは暗号化されたローカル履歴を正として全履歴を毎回送る。API側へも保存すると
            // BYOK接続の保持方針が暗黙に変わるため、まず stateless で比較可能にする。
            "store": .bool(false)
        ]
        if !instructions.isEmpty { object["instructions"] = .string(instructions) }
        if let temperature = request.temperature { object["temperature"] = .double(temperature) }
        if let effort = request.reasoningEffort, !effort.isEmpty {
            object["reasoning"] = .object(["effort": .string(effort)])
        }
        if let tools = request.tools, !tools.isEmpty {
            object["tools"] = .array(tools.map { tool in
                var value: [String: JSONValue] = [
                    "type": .string("function"),
                    "name": .string(tool.function.name),
                    "parameters": tool.function.parameters,
                    // Chat Completions 経路と同じ寛容なschema契約を保つ。strict移行はMCP schemaの
                    // additionalProperties/requiredを監査してから別判断にする。
                    "strict": .bool(false)
                ]
                if let description = tool.function.description { value["description"] = .string(description) }
                return .object(value)
            })
        }
        return .object(object)
    }

    private static func defaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }

    private static func collectBody(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes { data.append(byte) }
        // エラー本文は診断用なので、不正UTF-8でも全体を捨てず置換文字で保持する。
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self)
    }
}
private struct ResponsesAccumulator {
    private struct PendingCall {
        var id: String
        var name: String
        var arguments: String
    }

    private var callsByIndex: [Int: PendingCall] = [:]
    private var emittedOutputStarted = false

    // Responses のevent typeを1つの状態機械で扱うためswitch分岐を維持する。
    // swiftlint:disable:next cyclomatic_complexity
    mutating func handle(
        _ event: JSONValue,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) throws -> Bool {
        guard let type = event["type"]?.stringValue else { return false }
        switch type {
        case "response.output_text.delta":
            if let delta = event["delta"]?.stringValue, !delta.isEmpty { continuation.yield(.textDelta(delta)) }
        case "response.output_item.added":
            guard event["item"]?["type"]?.stringValue == "function_call" else { return false }
            let index = event["output_index"]?.intValue ?? callsByIndex.count
            callsByIndex[index] = PendingCall(
                id: event["item"]?["call_id"]?.stringValue ?? event["item"]?["id"]?.stringValue ?? "call_\(index)",
                name: event["item"]?["name"]?.stringValue ?? "",
                arguments: event["item"]?["arguments"]?.stringValue ?? ""
            )
            if !emittedOutputStarted {
                continuation.yield(.outputStarted)
                emittedOutputStarted = true
            }
        case "response.function_call_arguments.delta":
            let index = event["output_index"]?.intValue ?? 0
            if callsByIndex[index] == nil {
                callsByIndex[index] = PendingCall(id: event["item_id"]?.stringValue ?? "call_\(index)", name: "", arguments: "")
            }
            callsByIndex[index]?.arguments += event["delta"]?.stringValue ?? ""
        case "response.output_item.done":
            guard event["item"]?["type"]?.stringValue == "function_call" else { return false }
            let index = event["output_index"]?.intValue ?? 0
            callsByIndex[index] = PendingCall(
                id: event["item"]?["call_id"]?.stringValue ?? callsByIndex[index]?.id ?? "call_\(index)",
                name: event["item"]?["name"]?.stringValue ?? callsByIndex[index]?.name ?? "",
                arguments: event["item"]?["arguments"]?.stringValue ?? callsByIndex[index]?.arguments ?? ""
            )
        case "response.completed":
            let calls = callsByIndex.sorted(by: { $0.key < $1.key }).map { _, pending in
                ToolCall(id: pending.id, function: .init(name: pending.name, arguments: pending.arguments))
            }
            let tokenUsage = usage(from: event["response"]?["usage"])
            continuation.yield(.completed(calls.isEmpty ? .stop : .toolCalls, calls, tokenUsage))
            return true
        case "response.failed", "response.incomplete", "error":
            let message = event["response"]?["error"]?["message"]?.stringValue
                ?? event["error"]?["message"]?.stringValue
                ?? event["message"]?.stringValue
                ?? type
            throw LLMClientError.responseError(message)
        default:
            break
        }
        return false
    }

    private func usage(from value: JSONValue?) -> Usage? {
        guard let input = value?["input_tokens"]?.intValue,
              let output = value?["output_tokens"]?.intValue else { return nil }
        return Usage(
            promptTokens: input,
            completionTokens: output,
            totalTokens: value?["total_tokens"]?.intValue ?? input + output,
            promptTokensDetails: .init(cachedTokens: value?["input_tokens_details"]?["cached_tokens"]?.intValue)
        )
    }
}

private extension JSONValue {
    var intValue: Int? {
        if case .int(let value) = self { return value }
        return nil
    }
}

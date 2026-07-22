// Services/LLM(T2) A.2 OpenAICompatClient(SSE→LLMEvent 翻訳)の単体テスト。
//
// 出典・関連: Sources/Services/LLM/{LLMClient,SSELineParser,OpenAICompatClient}.swift
// (T2 実装コード。ここでは変更しない・振る舞いだけ固定する)。
import Foundation
import Testing

@testable import Kernel
@testable import Services

// MARK: - A.2 OpenAICompatClient(SSE→LLMEvent 翻訳)

/// テスト専用の URLProtocol スタブ。登録済みハンドラで固定レスポンスを返し、
/// 実ネットワークに一切出ずに OpenAICompatClient の SSE 読み取りパスを検証する
/// (T2 指示 B の推奨方式どおり)。
final class StubURLProtocol: URLProtocol {
    /// tuple の位置依存を避け、スタブ応答の各要素を呼び出し側でも明示する。
    struct Response {
        let statusCode: Int
        let headers: [String: String]
        let body: Data
    }

    /// テストごとに差し替えるハンドラ。(statusCode, headers, body bytes) を返す。
    static var handler: (@Sendable (URLRequest) -> Response)?

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let stubResponse = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stubResponse.statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: stubResponse.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stubResponse.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// .serialized: StubURLProtocol.handler は class 静的変数(全テスト共有)なので、swift-testing の
// 既定の並列実行のままだと2つのテストが同時に startLoading() を呼び、片方が別テストの
// handler を読んでしまう(実際に発生を確認: 並列実行時のみ HTTP401 系テストが原因不明の
// デコードエラーで落ちた)。Suite 全体を直列化してこの競合を避ける。
//
// 【経緯: bytes.lines の空行欠落バグ → 修正済み】(P3 T2 検証で発見・その後 Sources を修正)
// 当初 OpenAICompatClient.consumeSSE は `URLSession.AsyncBytes.lines` の各行を
// SSELineParser.consume(line:) に渡し、`line.isEmpty` を SSE イベント境界(空行)の合図に
// していた。ところがこのマシンの Swift 6.3(macOS 26)の stdlib `.lines` は **本当に空の行
// (2つの改行が連続する箇所)を1つも yield しない**("a\n\nb" → ["a","b"]・空白1文字を挟むと
// 消えない = 「本当に空」の行だけ失われる。最小 AsyncSequence + 本番 OpenAI/gpt-5.4-mini の
// ライブ検証で二重に再現)。そのため境界が来ず、全 data が連結されて DecodingError で落ちた。
// → 修正: consumeSSE を `.lines` 非経由にし、生バイト列を自前で \n 分割(空行を "" として保持・
//   末尾 \r 除去)する実装に置き換えた(OpenAICompatClient.swift のコメント参照)。SSELineParser は
//   もとから正しいので無変更。下記4テスト(content 連結・tool_calls 連結・usage-only・DONE 終端)は
//   その修正で通るようになったため disabled を外してある(期待値は仕様どおりのまま)。
@Suite(.serialized) struct OpenAICompatClientTests {
    /// completed event の関連値を名前付きで検証し、tuple index 依存を避ける。
    private struct Completion {
        let reason: FinishReason
        let calls: [ToolCall]
        let usage: Usage?
    }

    // StubURLProtocol を差し込んだ URLSession を作る。テストごとに専用 configuration を
    // 使うので、テスト間で handler の競合(並列実行時の取り違え)は起きない。
    private func makeStubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    private func makeClient(session: URLSession) -> OpenAICompatClient {
        OpenAICompatClient(
            baseURL: URL(string: "https://example.invalid/v1/chat/completions")!,
            apiKey: "test-key",
            urlSession: session
        )
    }

    private func makeRequest() -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: "gpt-test",
            messages: [ChatMessage(role: .user, content: "hi")],
            stream: true
        )
    }

    /// SSE イベント列を "data: ...\n\n" 形式にまとめてバイト列化するヘルパ。
    private func sseBody(_ payloads: [String]) -> Data {
        let text = payloads.map { "data: \($0)\n\n" }.joined()
        return Data(text.utf8)
    }

    // content delta が複数チャンクに分かれても、順番どおり .textDelta が出て、
    // 最後にちょうど1回 .completed(.stop, [], usage) が出る。
    @Test
    func contentDeltaが順に流れ最後にcompletedが1回() async throws {
        let body = sseBody([
            #"{"id":"c1","choices":[{"index":0,"delta":{"role":"assistant"},"finish_reason":null}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{"content":"Hel"},"finish_reason":null}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{"content":"lo"},"finish_reason":null}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            #"{"id":"c1","choices":[],"usage":{"prompt_tokens":5,"completion_tokens":2,"total_tokens":7}}"#,
            "[DONE]"
        ])
        StubURLProtocol.handler = { _ in
            .init(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: body)
        }

        let client = makeClient(session: makeStubbedSession())
        var textDeltas: [String] = []
        var completions: [Completion] = []
        for try await event in client.stream(makeRequest()) {
            switch event {
            case .textDelta(let text): textDeltas.append(text)
            case .completed(let reason, let calls, let usage):
                completions.append(.init(reason: reason, calls: calls, usage: usage))
            }
        }

        #expect(textDeltas == ["Hel", "lo"])
        #expect(completions.count == 1)
        #expect(completions[0].reason == .stop)
        #expect(completions[0].calls.isEmpty)
        #expect(completions[0].usage == Usage(promptTokens: 5, completionTokens: 2, totalTokens: 7))
    }

    // tool_calls: 初回 delta(id + function.name)+ 継続 delta(arguments 断片複数)が
    // 最終 completed の [ToolCall] で1件・arguments 連結済みに確定する。
    @Test
    func toolCallsのdeltaが連結して1件に確定する() async throws {
        let body = sseBody([
            #"{"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"get_weather","arguments":""}}]},"finish_reason":null}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"city\":"}}]},"finish_reason":null}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"Tokyo\"}"}}]},"finish_reason":null}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}"#,
            "[DONE]"
        ])
        StubURLProtocol.handler = { _ in
            .init(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: body)
        }

        let client = makeClient(session: makeStubbedSession())
        var completions: [Completion] = []
        for try await event in client.stream(makeRequest()) {
            if case .completed(let reason, let calls, let usage) = event {
                completions.append(.init(reason: reason, calls: calls, usage: usage))
            }
        }

        #expect(completions.count == 1)
        #expect(completions[0].reason == .toolCalls)
        #expect(completions[0].calls == [
            ToolCall(id: "call_1", function: .init(name: "get_weather", arguments: "{\"city\":\"Tokyo\"}"))
        ])
    }

    // usage-only チャンク(choices:[])が来てもデコードが壊れず、usage が completed に載る
    // (設計 §2 の MUST: choices[0] を無条件に仮定しない)。
    @Test
    func usageOnlyチャンクでデコードが壊れない() async throws {
        let body = sseBody([
            #"{"id":"c1","choices":[{"index":0,"delta":{"content":"ok"},"finish_reason":null}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            #"{"id":"c1","choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}"#,
            "[DONE]"
        ])
        StubURLProtocol.handler = { _ in
            .init(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: body)
        }

        let client = makeClient(session: makeStubbedSession())
        var usage: Usage?
        for try await event in client.stream(makeRequest()) {
            if case .completed(_, _, let completedUsage) = event { usage = completedUsage }
        }
        #expect(usage == Usage(promptTokens: 1, completionTokens: 1, totalTokens: 2))
    }

    // [DONE] で終端したとき、completed はちょうど1回だけ yield される。
    @Test
    func DONEでcompletedはちょうど1回() async throws {
        let body = sseBody([
            #"{"id":"c1","choices":[{"index":0,"delta":{"content":"x"},"finish_reason":null}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            "[DONE]"
        ])
        StubURLProtocol.handler = { _ in
            .init(statusCode: 200, headers: ["Content-Type": "text/event-stream"], body: body)
        }

        let client = makeClient(session: makeStubbedSession())
        var completedCount = 0
        for try await event in client.stream(makeRequest()) {
            if case .completed = event { completedCount += 1 }
        }
        #expect(completedCount == 1)
    }

    // HTTP 401 応答は LLMClientError.httpError としてストリームの throw に出る。
    @Test func HTTP401はhttpErrorとしてthrowされる() async throws {
        let body = Data(#"{"error":{"message":"invalid api key"}}"#.utf8)
        StubURLProtocol.handler = { _ in
            .init(statusCode: 401, headers: ["Content-Type": "application/json"], body: body)
        }

        let client = makeClient(session: makeStubbedSession())
        await #expect(throws: LLMClientError.self) {
            for try await _ in client.stream(makeRequest()) {}
        }
    }
}

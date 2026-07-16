// Services/LLM(T2)の単体テスト: SSELineParser(純関数)・OpenAICompatClient(SSE→LLMEvent
// 翻訳)・ToolConversion(MCP tools/list → OpenAI ToolDefinition)・AppsServerProxy の
// app 発 tools/call 拒否(visibility)。
//
// 出典・関連: Sources/Services/LLM/{LLMClient,SSELineParser,OpenAICompatClient,ToolConversion}.swift
// (T2 実装コード。ここでは変更しない・振る舞いだけ固定する)。P3 T2 指示書の A.1〜A.4 に対応する
// 4つの @Suite に分ける(責務ごとにテストファイルを追わずに済むよう1ファイルに収めるが、
// Suite は指示書の項番に対応させておく)。
import Foundation
import Testing
import MCP

@testable import Kernel
@testable import Services

// MARK: - A.1 SSELineParser

@Suite struct SSELineParserTests {
    // 単一 data 行 + 空行 → 1 payload が返る(最も基本の1イベント)。
    @Test func data1行と空行で1payloadを返す() {
        var parser = SSELineParser()
        #expect(parser.consume(line: "data: {\"a\":1}") == nil)
        #expect(parser.consume(line: "") == "{\"a\":1}")
    }

    // 複数 data 行は \n 連結されて1 payload になる(SSE 仕様の dispatch 手順)。
    @Test func 複数data行は改行連結される() {
        var parser = SSELineParser()
        #expect(parser.consume(line: "data: line1") == nil)
        #expect(parser.consume(line: "data: line2") == nil)
        #expect(parser.consume(line: "") == "line1\nline2")
    }

    // コメント行(":" で始まる。SSE のキープアライブ)は無視され、後続の data には影響しない。
    @Test func コメント行は無視される() {
        var parser = SSELineParser()
        #expect(parser.consume(line: ": ping") == nil)
        #expect(parser.consume(line: "data: hello") == nil)
        #expect(parser.consume(line: "") == "hello")
    }

    // data: [DONE] は "data:" 接頭辞を剥がした "[DONE]" が payload として返る
    // (OpenAICompatClient 側がこの文字列で終端判定する契約)。
    @Test func DONE行はDONE文字列を返す() {
        var parser = SSELineParser()
        #expect(parser.consume(line: "data: [DONE]") == nil)
        #expect(parser.consume(line: "") == "[DONE]")
    }

    // 空行のみ連続(data 行を1つも見ていない)場合は nil(空イベントは無視・意味的な区切りなし)。
    @Test func data無しの空行はnilを返す() {
        var parser = SSELineParser()
        #expect(parser.consume(line: "") == nil)
        #expect(parser.consume(line: "") == nil)
    }

    // fieldValue: 先頭スペース1つだけを剥がす(SSE 仕様どおり。値内の以降のスペースは保持)。
    @Test func fieldValueは先頭スペース1つだけ剥がす() {
        #expect(SSELineParser.fieldValue(line: "data:  x", field: "data") == " x")
        #expect(SSELineParser.fieldValue(line: "data:x", field: "data") == "x")
        #expect(SSELineParser.fieldValue(line: "event: foo", field: "data") == nil)
    }

    // flush(): 空行で締めずに data が残留したまま終端した場合、flush がその残留分を返す
    // (末尾に空行が無いまま接続が閉じる実装揺れへの保険)。
    @Test func flushは空行未確定のdataを返す() {
        var parser = SSELineParser()
        #expect(parser.consume(line: "data: tail") == nil)
        #expect(parser.flush() == "tail")
        // flush 後はバッファがクリアされるので再度呼んでも nil。
        #expect(parser.flush() == nil)
    }
}

// MARK: - A.2 OpenAICompatClient(SSE→LLMEvent 翻訳)

/// テスト専用の URLProtocol スタブ。登録済みハンドラで固定レスポンスを返し、
/// 実ネットワークに一切出ずに OpenAICompatClient の SSE 読み取りパスを検証する
/// (T2 指示 B の推奨方式どおり)。
final class StubURLProtocol: URLProtocol {
    /// テストごとに差し替えるハンドラ。(statusCode, headers, body bytes) を返す。
    static var handler: (@Sendable (URLRequest) -> (Int, [String: String], Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (statusCode, headers, body) = handler(request)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
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
            "[DONE]",
        ])
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "text/event-stream"], body) }

        let client = makeClient(session: makeStubbedSession())
        var textDeltas: [String] = []
        var completions: [(FinishReason, [ToolCall], Usage?)] = []
        for try await event in client.stream(makeRequest()) {
            switch event {
            case .textDelta(let text): textDeltas.append(text)
            case .completed(let reason, let calls, let usage): completions.append((reason, calls, usage))
            }
        }

        #expect(textDeltas == ["Hel", "lo"])
        #expect(completions.count == 1)
        #expect(completions[0].0 == .stop)
        #expect(completions[0].1.isEmpty)
        #expect(completions[0].2 == Usage(promptTokens: 5, completionTokens: 2, totalTokens: 7))
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
            "[DONE]",
        ])
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "text/event-stream"], body) }

        let client = makeClient(session: makeStubbedSession())
        var completions: [(FinishReason, [ToolCall], Usage?)] = []
        for try await event in client.stream(makeRequest()) {
            if case .completed(let reason, let calls, let usage) = event {
                completions.append((reason, calls, usage))
            }
        }

        #expect(completions.count == 1)
        #expect(completions[0].0 == .toolCalls)
        #expect(completions[0].1 == [
            ToolCall(id: "call_1", function: .init(name: "get_weather", arguments: "{\"city\":\"Tokyo\"}")),
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
            "[DONE]",
        ])
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "text/event-stream"], body) }

        let client = makeClient(session: makeStubbedSession())
        var usage: Usage?
        for try await event in client.stream(makeRequest()) {
            if case .completed(_, _, let u) = event { usage = u }
        }
        #expect(usage == Usage(promptTokens: 1, completionTokens: 1, totalTokens: 2))
    }

    // [DONE] で終端したとき、completed はちょうど1回だけ yield される。
    @Test
    func DONEでcompletedはちょうど1回() async throws {
        let body = sseBody([
            #"{"id":"c1","choices":[{"index":0,"delta":{"content":"x"},"finish_reason":null}]}"#,
            #"{"id":"c1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            "[DONE]",
        ])
        StubURLProtocol.handler = { _ in (200, ["Content-Type": "text/event-stream"], body) }

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
        StubURLProtocol.handler = { _ in (401, ["Content-Type": "application/json"], body) }

        let client = makeClient(session: makeStubbedSession())
        await #expect(throws: LLMClientError.self) {
            for try await _ in client.stream(makeRequest()) {}
        }
    }
}

// MARK: - A.3 ToolConversion

@Suite struct ToolConversionTests {
    // _meta.ui.visibility に "model" を含まないツール(["app"] のみ)は結果から落ちる
    // (apps.mdx:400 MUST)。
    @Test func visibilityがappのみのツールは除外される() throws {
        let tool = Tool(
            name: "refresh-todos",
            description: "internal refresh",
            inputSchema: .object(["type": .string("object")]),
            _meta: Metadata(additionalFields: [
                "ui": .object(["visibility": .array([.string("app")])]),
            ]))
        let definitions = try toolDefinitions(from: [tool])
        #expect(definitions.isEmpty)
    }

    // _meta 省略・["model","app"]・["model"] を含むツールはいずれも結果に残る。
    @Test func modelを含むまたはmeta省略のツールは残る() throws {
        let noMeta = Tool(name: "get-current-time", description: "test", inputSchema: .object([:]))
        let modelAndApp = Tool(
            name: "list-todos",
            description: "test",
            inputSchema: .object([:]),
            _meta: Metadata(additionalFields: [
                "ui": .object(["visibility": .array([.string("model"), .string("app")])]),
            ]))
        let modelOnly = Tool(
            name: "delete-todo",
            description: "test",
            inputSchema: .object([:]),
            _meta: Metadata(additionalFields: [
                "ui": .object(["visibility": .array([.string("model")])]),
            ]))

        let definitions = try toolDefinitions(from: [noMeta, modelAndApp, modelOnly])
        let names = Set(definitions.map { $0.function.name })
        #expect(names == ["get-current-time", "list-todos", "delete-todo"])
    }

    // inputSchema(MCP.Value の object)が ToolDefinition.function.parameters に
    // JSON Schema としてそのまま移り、properties/required が保たれる。
    @Test func inputSchemaがJSONSchemaとして移る() throws {
        let tool = Tool(
            name: "get_weather",
            description: "weather lookup",
            inputSchema: .object([
                "type": .string("object"),
                "properties": .object([
                    "city": .object(["type": .string("string")]),
                ]),
                "required": .array([.string("city")]),
            ]))

        let definitions = try toolDefinitions(from: [tool])
        #expect(definitions.count == 1)
        let parameters = definitions[0].function.parameters
        #expect(parameters["type"]?.stringValue == "object")
        #expect(parameters["properties"]?["city"]?["type"]?.stringValue == "string")
        #expect(parameters["required"]?.arrayValue == [.string("city")])
    }
}

// MARK: - A.4 AppsServerProxy の app 発 tools/call 拒否

@Suite struct AppsServerProxyVisibilityTests {
    private func makeProxy() -> AppsServerProxy {
        AppsServerProxy(client: Client(name: "test", version: "0"))
    }

    // visibility ["model"] のみ(app 不可)のツールへの app 発 tools/call は
    // toolNotAppCallable で拒否される(apps.mdx:401 MUST)。
    @Test func appを含まないツールはtoolNotAppCallableで拒否される() async {
        let proxy = makeProxy()
        let modelOnlyTool = Tool(
            name: "delete-todo",
            description: "test",
            inputSchema: .object([:]),
            _meta: Metadata(additionalFields: [
                "ui": .object(["visibility": .array([.string("model")])]),
            ]))
        await proxy.setTools([modelOnlyTool])

        let params: JSONValue = ["name": "delete-todo", "arguments": [:]]
        await #expect(throws: AppsServerProxyError.self) {
            _ = try await proxy.passthroughToolsCall(params: params)
        }
    }

    // _meta 省略(既定 visibility に "app" を含む)のツール名は判定を通過する
    // (この先の callTool 実行で Client 未接続エラーになるはずなので、それを検知できれば
    // 「visibility 判定では拒否されなかった」ことの傍証になる。toolNotAppCallable **ではない**
    // 別種のエラーで失敗することを確認する)。
    @Test func meta省略のツールは判定を通過する() async {
        let proxy = makeProxy()
        let noMetaTool = Tool(name: "list-todos", description: "test", inputSchema: .object([:]))
        await proxy.setTools([noMetaTool])

        let params: JSONValue = ["name": "list-todos", "arguments": [:]]
        do {
            _ = try await proxy.passthroughToolsCall(params: params)
            Issue.record("接続していない Client への callTool は成功しないはず")
        } catch let error as AppsServerProxyError {
            if case .toolNotAppCallable = error {
                Issue.record("visibility 判定で拒否されるべきではない: \(error)")
            }
            // missingField 等それ以外の AppsServerProxyError は許容(判定は通過している)。
        } catch {
            // Client 未接続による MCPError 等はここに落ちる。visibility 判定は通過している。
        }
    }

    // 一覧に無い名前は(visibility を根拠にした)拒否をしない。この分岐は Client の実行結果を
    // 問わないので、toolNotAppCallable **ではない**理由で失敗することだけを確認する。
    @Test func 一覧に無い名前はvisibilityでは拒否しない() async {
        let proxy = makeProxy()
        await proxy.setTools([])

        let params: JSONValue = ["name": "unknown-tool", "arguments": [:]]
        do {
            _ = try await proxy.passthroughToolsCall(params: params)
            Issue.record("接続していない Client への callTool は成功しないはず")
        } catch let error as AppsServerProxyError {
            if case .toolNotAppCallable = error {
                Issue.record("一覧に無い名前を visibility で拒否してはいけない: \(error)")
            }
        } catch {
            // Client 未接続による例外はここに落ちる。想定どおり。
        }
    }

    // 一覧未注入(setTools を呼ばない)は後方互換で全許可 → visibility 判定では拒否しない。
    @Test func 一覧未注入は全許可で判定を通過する() async {
        let proxy = makeProxy()
        let params: JSONValue = ["name": "anything", "arguments": [:]]
        do {
            _ = try await proxy.passthroughToolsCall(params: params)
            Issue.record("接続していない Client への callTool は成功しないはず")
        } catch let error as AppsServerProxyError {
            if case .toolNotAppCallable = error {
                Issue.record("一覧未注入は全許可のはず: \(error)")
            }
        } catch {
            // Client 未接続による例外はここに落ちる。想定どおり。
        }
    }
}

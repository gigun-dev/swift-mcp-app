import Foundation
import OpenTelemetryProtocolExporterCommon
import Testing

@testable import Kernel
@testable import Services

// MCPの論理エラーとHTTPの失敗を混同しない。transportは正常に返り、引数の意味が不正という
// isError:trueを再現する。実サービスに不正リクエストを送り続けず、既存のLLM/実行口stubを使う。
@MainActor
@Suite(.serialized)
struct ToolFailureLoopVerificationTests {
    private let errorResult: JSONValue = .object([
        "isError": .bool(true),
        "content": .array([.object([
            "type": .string("text"), "text": .string("Invalid timeZone: Not/AZone")
        ])]),
        "structuredContent": .object(["reason": .string("invalid-timezone")]),
        "_meta": .object(["ui": .object(["resourceUri": .string("ui://agenda")])])
    ])

    @Test func logicalMCPErrorShouldShowFailedStep() async throws {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.toolCalls, [call(index: 1)], nil)],
            [.textDelta("invalid timezone"), .completed(.stop, [], nil)]
        ])
        let viewModel = ChatViewModel(
            llm: llm, toolExecutor: StubToolExecutor(results: ["get_agenda": errorResult]),
            tools: [], model: "verification-model", systemPrompt: nil
        )
        await viewModel.send("synthetic invalid arguments")
        let step = try #require(viewModel.turns.flatMap(\.toolSteps).first)
        let resultMessage = try #require(llm.receivedRequests[1].messages.first { $0.role == .tool })
        let resultData = try #require(resultMessage.content?.data(using: .utf8))
        #expect(try JSONDecoder().decode(JSONValue.self, from: resultData) == errorResult)
        print("MCP_LOGICAL_ERROR_OBSERVED step_state=\(step.state) next_request_result_preserved=true")
        #expect(step.state == .failed)
        let storedData = try #require(step.resultJSON?.data(using: .utf8))
        #expect(try JSONDecoder().decode(JSONValue.self, from: storedData) == errorResult)
        #expect(viewModel.turns.flatMap(\.cards).isEmpty)
    }

    @Test func repeatedInvalidArgumentsPreserveEveryResultAndLimitShouldMarkTurnError() async throws {
        let receiver = try LoopSpanReceiver()
        defer { receiver.stop() }
        let endpoint = try await receiver.endpoint()
        let telemetry = OpenTelemetryService(configuration: .init(endpoint: endpoint))
        // 引数は8回とも同じ。call IDだけは実LLM同様に別IDとして履歴の対応関係を検証する。
        let llm = ScriptedLLMClient(scripts: (1 ... 8).map {
            [.completed(.toolCalls, [call(index: $0)], nil)]
        })
        let executor = StubToolExecutor(results: ["get_agenda": errorResult])
        let viewModel = ChatViewModel(
            llm: llm, toolExecutor: executor, tools: [], model: "verification-model", systemPrompt: nil,
            traceSink: telemetry, telemetry: telemetry
        )
        await viewModel.send("synthetic repeated invalid arguments")
        #expect(llm.callCount == 8)
        #expect(await executor.calls.count == 8)
        #expect(viewModel.errorMessage?.contains("最大反復(8回)") == true)
        #expect(!viewModel.isRunning)

        for (index, request) in llm.receivedRequests.enumerated() {
            let calls = request.messages.flatMap { $0.toolCalls ?? [] }
            let results = request.messages.filter { $0.role == .tool }
            #expect(calls.count == index)
            #expect(results.count == index)
            #expect(Set(calls.map(\.id)) == Set(results.compactMap(\.toolCallId)))
            for result in results {
                let data = try #require(result.content?.data(using: .utf8))
                #expect(try JSONDecoder().decode(JSONValue.self, from: data) == errorResult)
            }
        }
        // 最終8件目は打切り後に新しいLLM requestを作らない。内部wireへの格納まで確認する。
        #expect(viewModel.wireMessages.filter { $0.role == .tool }.count == 8)
        let batch = try await receiver.batch()
        let spans = batch.resourceSpans.flatMap(\.scopeSpans).flatMap(\.spans)
        let turn = try #require(spans.first { $0.name == "chat.turn" })
        let toolSpans = spans.filter { $0.name == "mcp.tool get_agenda" }
        #expect(toolSpans.count == 8)
        #expect(toolSpans.allSatisfy { $0.status.code == .error })
        print("MCP_LOOP_OBSERVED llm_requests=8 tool_results_in_wire=8 next_requests_preserve_all_prior_results=true tool_error_spans=\(toolSpans.count) turn_status=\(turn.status.code)")
        #expect(turn.status.code == .error)
        #expect(turn.status.message.contains("最大反復(8回)"))
        #expect(turn.attributes.contains { $0.key == "chat.iterations" && $0.value.intValue == 8 })
    }

    // 失敗したtoolの後でモデルが回答できた場合、親会話は成功。最終許容反復で.stopを
    // 受け取った場合も上限打切りにしない。toolなしのmax=1も同じ終了境界で確認する。
    @Test(arguments: ["text", "successful-tool", "recovered-error"])
    func completedTurnIsOKAtLastAllowedIteration(scenario: String) async throws {
        let receiver = try LoopSpanReceiver()
        defer { receiver.stop() }
        let telemetry = OpenTelemetryService(configuration: .init(endpoint: try await receiver.endpoint()))
        let usesTool = scenario != "text"
        let result: JSONValue = scenario == "recovered-error" ? errorResult : .object([
            "isError": .bool(false), "content": .array([
                .object(["type": .string("text"), "text": .string("success")])
            ])
        ])
        var scripts: [[LLMEvent]] = []
        if usesTool { scripts.append([.completed(.toolCalls, [call(index: 1)], nil)]) }
        scripts.append([.textDelta("completed"), .completed(.stop, [], nil)])
        let llm = ScriptedLLMClient(scripts: scripts)
        let viewModel = ChatViewModel(
            llm: llm, toolExecutor: StubToolExecutor(results: ["get_agenda": result]),
            tools: [], model: "verification-model", systemPrompt: nil, maxIterations: scripts.count,
            traceSink: telemetry, telemetry: telemetry
        )
        await viewModel.send("synthetic completion boundary")
        #expect(viewModel.errorMessage == nil)
        #expect(llm.callCount == scripts.count)
        #expect(viewModel.turns.last?.text == "completed")
        let batch = try await receiver.batch()
        let spans = batch.resourceSpans.flatMap(\.scopeSpans).flatMap(\.spans)
        let turn = try #require(spans.first { $0.name == "chat.turn" })
        #expect(turn.status.code == .ok)
        if usesTool {
            let step = try #require(viewModel.turns.flatMap(\.toolSteps).first)
            #expect(step.state == (scenario == "recovered-error" ? .failed : .done))
            let tool = try #require(spans.first { $0.name == "mcp.tool get_agenda" })
            #expect(tool.status.code == (scenario == "recovered-error" ? .error : .ok))
        }
    }

    private func call(index: Int) -> ToolCall {
        ToolCall(id: "call-\(index)", function: .init(
            name: "get_agenda", arguments: #"{"timeZone":"Not/AZone"}"#
        ))
    }

    // 正常HTTP EOF・Content-Length未達の通信断・中立adapterのcompleted欠落を同じ
    // 会話境界で確認する。部分本文は残すが不完全toolは実行せず、OTLPにも誤ったOKを送らない。
    @Test(arguments: ["eof", "truncated", "no-completed"])
    func unfinishedGenerationKeepsPartialTextAndEndsAsError(mode: String) async throws {
        let server = try BoundaryStreamServer(duration: 0)
        defer { server.stop() }
        let receiver = try LoopSpanReceiver()
        defer { receiver.stop() }
        let telemetry = OpenTelemetryService(configuration: .init(endpoint: try await receiver.endpoint()))
        let endpoint = try await server.baseURL().appendingPathComponent(mode).appendingPathComponent("v1")
        let llm: any LLMClient = mode == "no-completed"
            ? ScriptedLLMClient(scripts: [[.textDelta("probe")]])
            : OpenAICompatClient(baseURL: endpoint, apiKey: "local-unused")
        let executor = StubToolExecutor()
        let viewModel = ChatViewModel(
            llm: llm, toolExecutor: executor, tools: [], model: "boundary", systemPrompt: nil,
            traceSink: telemetry, telemetry: telemetry
        )
        await viewModel.send("synthetic incomplete generation")
        // TCP即切断ではdeltaがconsumerへ届く保証はない。配送済み本文の保持は
        // no-completedのscriptで必ず確認し、未配送の通信断も会話失敗として扱う。
        let text = try #require(viewModel.turns.last?.text)
        #expect(mode == "truncated" ? (text.isEmpty || text == "probe") : text == "probe")
        #expect(viewModel.errorMessage?.contains("LLM ストリームに失敗") == true)
        #expect(!viewModel.isRunning)
        #expect(await executor.calls.isEmpty)
        #expect(viewModel.turns.flatMap(\.toolSteps).isEmpty)
        let batch = try await receiver.batch()
        let spans = batch.resourceSpans.flatMap(\.scopeSpans).flatMap(\.spans)
        for name in ["llm.generation", "chat.turn"] {
            let span = try #require(spans.first { $0.name == name })
            #expect(span.status.code == .error)
        }
    }
}

// HTTP receiverはOTLP成功応答だけを返す。gzipとprotobufを実際に読み、SDK内部状態の推測を避ける。
// port0/一時ディレクトリは他のInspectorや検証と競合しない。保存はテスト終了までの一時的なもの。
private final class LoopSpanReceiver {
    private let directory: URL
    private let process = Process()

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", Self.script, directory.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }

    func endpoint() async throws -> URL {
        let data = try await waitForFile("port")
        let port = try #require(String(data: data, encoding: .utf8))
        return try #require(URL(string: "http://127.0.0.1:\(port)/v1/traces"))
    }

    func batch() async throws -> Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest {
        try await .init(serializedBytes: waitForFile("batch.pb"))
    }

    private func waitForFile(_ name: String) async throws -> Data {
        // 既定batch delay5秒に対して25秒を上限に実受信を待つ。到着しなければテストを失敗させる。
        for _ in 0 ..< 250 {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)) { return data }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    private static let script = #"""
import gzip, http.server, pathlib, sys
root = pathlib.Path(sys.argv[1])
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        data = self.rfile.read(int(self.headers['Content-Length']))
        if self.headers.get('Content-Encoding') == 'gzip': data = gzip.decompress(data)
        temp = root / 'receiving.tmp'
        temp.write_bytes(data)
        temp.replace(root / 'batch.pb')
        self.send_response(200)
        self.send_header('Content-Length', '0')
        self.end_headers()
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
"""#
}

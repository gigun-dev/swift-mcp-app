import Foundation
import MCP
import Testing

@testable import Kernel
@testable import Services

// 任意引数をrequiredへ変えると、モデルに空文字placeholderを強制する可能性がある。
// SDK Toolから両APIの実wire schemaまで同じfixtureを通し、内容保持を検証する。
@Suite struct SchemaAndStreamBoundaryVerificationTests {
    @Test func optionalArgumentsStayOptionalAcrossBothAPIAdapters() throws {
        let schema: MCP.Value = .object([
            "type": .string("object"),
            "properties": .object([
                "range": .object(["type": .string("string"), "enum": .array([.string("today")])]),
                "timeMin": .object(["type": .string("string"), "format": .string("date-time")]),
                "timeMax": .object(["type": .string("string"), "format": .string("date-time")]),
                "timeZone": .object(["type": .string("string"), "default": .string("Asia/Tokyo")])
            ]),
            "required": .array([.string("timeZone")]),
            "additionalProperties": .bool(false)
        ])
        let tool = Tool(name: "list-events-expanded", description: "calendar", inputSchema: schema)
        let original = try JSONValue(encoding: schema)
        // 名前空間化がschemaを変更しないことも確認する。app-only除外は既存suiteが所有する。
        for definitions in [
            try toolDefinitions(from: [tool]),
            try prefixedToolDefinitions(from: [tool], slug: "calendar", serverName: "Calendar")
        ] {
            let request = ChatCompletionRequest(model: "test", messages: [], tools: definitions, stream: true)
            let chat = try JSONValue(encoding: request)
            let chatTool = try #require(chat["tools"]?.arrayValue?.first?["function"])
            #expect(chatTool["parameters"] == original)
            #expect(chatTool["strict"] == .bool(false))
            let responses = OpenAIResponsesClient.responsesBody(from: request)
            let responsesTool = try #require(responses["tools"]?.arrayValue?.first)
            #expect(responsesTool["parameters"] == original)
            #expect(responsesTool["strict"] == .bool(false))
        }
    }

    // 通常gateは短く実行し、調査時だけ環境変数で65秒等の継続streamを指定する。
    // URLProtocol stubではなくloopback TCPを使い、実URLSession.AsyncBytesのEOF/throwを確認する。
    @Test(arguments: [false, true])
    func streamingBoundaryUsesRealTCP(responses: Bool) async throws {
        let duration = Double(ProcessInfo.processInfo.environment["MCPHOST_VERIFY_STREAM_SECONDS"] ?? "0.05") ?? 0.05
        let server = try BoundaryStreamServer(duration: duration)
        defer { server.stop() }
        let base = try await server.baseURL()
        let request = ChatCompletionRequest(
            model: "boundary", messages: [.init(role: .user, content: "probe")], stream: true
        )
        let modes = responses ? ["complete", "truncated", "eof"]
            : ["complete", "truncated", "eof", "finish-only", "done-only", "done-no-newline"]
        for mode in modes {
            let endpoint = base.appendingPathComponent(mode).appendingPathComponent("v1")
            let client: any LLMClient = responses
                ? OpenAIResponsesClient(baseURL: endpoint, apiKey: "local-unused")
                : OpenAICompatClient(baseURL: endpoint, apiKey: "local-unused")
            var text = ""
            var reasons: [FinishReason] = []
            var failure: Error?
            let start = ContinuousClock.now
            do {
                for try await event in client.stream(request) {
                    if case .textDelta(let delta) = event { text += delta }
                    if case .completed(let reason, _, _) = event { reasons.append(reason) }
                }
            } catch { failure = error }
            let elapsed = start.duration(to: .now)
            // Content-Length未達の即切断はURLSessionがbodyを配送する前にthrowしうる。
            // 未配送を本文消失と誤診せず、配送済みdeltaの保持はVMの決定的fixtureで検証する。
            #expect(mode == "truncated" ? (text.isEmpty || text == "probe") : text == "probe")
            if mode == "complete" || mode == "finish-only" {
                #expect(failure == nil)
                #expect(reasons == [.stop])
            } else if mode.hasPrefix("done-") {
                #expect(failure == nil)
                #expect(reasons == [.other("no_finish_reason")])
            } else if mode == "truncated" {
                // Content-Length未達でTCPを閉じる。通信例外はcompletedへ変換されない。
                #expect(failure != nil)
                #expect(reasons.isEmpty)
                let networkError = try #require(failure as? URLError)
                #expect(networkError.code == .networkConnectionLost)
            } else {
                // HTTP自体の正常EOFでも生成完了印が無ければ、両adapterとも未確定として失敗。
                #expect(failure != nil)
                #expect(reasons.isEmpty)
            }
            let nsError = failure.map { $0 as NSError }
            print("STREAM_BOUNDARY api=\(responses ? "responses" : "chat") mode=\(mode) elapsed=\(elapsed) completed=\(reasons.count) error_domain=\(nsError?.domain ?? "none") error_code=\(nsError?.code ?? 0)")
        }
    }
}

final class BoundaryStreamServer {
    private let directory: URL
    private let process = Process()

    init(duration: Double) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", Self.script, directory.path, String(max(0, duration))]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    func stop() {
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: directory)
    }

    func baseURL() async throws -> URL {
        for _ in 0 ..< 100 {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("port")),
               let port = String(data: data, encoding: .utf8),
               let url = URL(string: "http://127.0.0.1:\(port)") { return url }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    // loopback/port0/個別processのみ。外部ホストも実資格情報も必要としない。
    private static let script = #"""
import http.server, json, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
duration = float(sys.argv[2])
def event(value):
    if 'choices' in value:
        value.update({'id': 'local', 'object': 'chat.completion.chunk', 'created': 0, 'model': 'boundary'})
    return ('data: ' + json.dumps(value) + '\n\n').encode()
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args): pass
    def do_POST(self):
        self.rfile.read(int(self.headers.get('Content-Length', 0)))
        responses = self.path.endswith('/responses')
        complete = '/complete/' in self.path
        truncated = '/truncated/' in self.path
        if responses:
            delta = event({'type': 'response.output_text.delta', 'delta': 'probe'})
            tail = event({'type': 'response.completed', 'response': {}})
        else:
            delta = event({'choices': [{'index': 0, 'delta': {'content': 'probe'}, 'finish_reason': None}]})
            finish = event({'choices': [{'index': 0, 'delta': {}, 'finish_reason': 'stop'}]})
            tail = finish + b'data: [DONE]\n\n'
            if '/eof/' in self.path or truncated:
                call = {'index': 0, 'id': 'partial', 'type': 'function',
                        'function': {'name': 'get_agenda', 'arguments': '{"timeZone":'}}
                delta += event({'choices': [{'index': 0, 'delta': {'tool_calls': [call]},
                                            'finish_reason': None}]})
            if '/finish-only/' in self.path: tail = finish
            if '/done-only/' in self.path: tail = b'data: [DONE]\n\n'
            if '/done-no-newline/' in self.path: tail = b'data: [DONE]'
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        if truncated: self.send_header('Content-Length', str(len(delta) + 1024))
        self.end_headers()
        self.wfile.write(delta)
        self.wfile.flush()
        if complete or '/finish-only/' in self.path or '/done-' in self.path:
            for _ in range(4):
                time.sleep(duration / 4)
                self.wfile.write(b': keepalive\n\n')
                self.wfile.flush()
            self.wfile.write(tail)
            self.wfile.flush()
        self.close_connection = True
server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
"""#
}

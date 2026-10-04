import Foundation
import Kernel
import OpenTelemetryProtocolExporterCommon
import Services
import Testing

// 実際の HTTP と gzip/protobuf exporter を通す。mock sink だけでは「配送できた」ことを
// 保証できず、本番への意図的な障害注入は他の利用者に影響するため loopback に閉じる。
@Suite(.serialized)
struct TelemetryFailureVerificationTests {
    @MainActor
    @Test(arguments: [false, true])
    func realConnectionLossIsExportedWithStageAndErrorParent(responses: Bool) async throws {
        let receiver = try FailureReceiver(disconnect: true)
        defer { receiver.stop() }
        let base = try await receiver.baseURL()
        let local = FailureRecordingTelemetry()
        let router = TelemetryRouter(localTelemetry: local)
        router.configure(.init(endpoint: base.appendingPathComponent("v1/traces")))
        let client: any LLMClient = responses
            ? OpenAIResponsesClient(baseURL: base.appendingPathComponent("v1"), apiKey: "test-only")
            : OpenAICompatClient(baseURL: base.appendingPathComponent("v1"), apiKey: "test-only")
        let viewModel = ChatViewModel(
            llm: client, toolExecutor: StubToolExecutor(), tools: [], model: "disconnect-verification-model",
            systemPrompt: nil, traceSink: router, telemetry: router
        )
        await viewModel.send("synthetic connection-loss verification")
        #expect(viewModel.errorMessage != nil)
        let batch = try await receiver.request(number: 0)
        let spans = batch.resourceSpans.flatMap(\.scopeSpans).flatMap(\.spans)
        let generation = try #require(spans.first { $0.name == "llm.generation" })
        let turn = try #require(spans.first { $0.name == "chat.turn" })
        let attributes = Dictionary(uniqueKeysWithValues: generation.attributes.map { ($0.key, $0.value.stringValue) })
        #expect(generation.status.code == .error)
        #expect(turn.status.code == .error)
        #expect(generation.parentSpanID == turn.spanID)
        #expect(generation.traceID == turn.traceID)
        #expect(attributes["error.domain"] == NSURLErrorDomain)
        #expect(attributes["error.code"] == "-1005")
        #expect(attributes["error.type"] == "\(NSURLErrorDomain):-1005")
        #expect(attributes["gen_ai.request.model"] == "disconnect-verification-model")
        #expect(attributes["llm.generation.failure_stage"] == "streaming_output")
        #expect(Int(attributes["duration_ms"] ?? "").map { $0 >= 100 } == true)
        #expect(attributes["llm.generation.response_headers_ms"] != nil)
        #expect(attributes["llm.generation.ttft_ms"] != nil)
        #expect(attributes["llm.generation.time_to_first_text_ms"] != nil)
        #expect(attributes["generation_id"] == local.errors().first?["generation_id"])
        #expect(viewModel.turns.last?.text == "probe")
        // 手動検証時だけ原本を保持する。通常gateでは既存receiver同様に一時データを削除する。
        if let path = ProcessInfo.processInfo.environment["MCPHOST_VERIFY_OTLP_DIRECTORY"] {
            let directory = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent(responses ? "responses.pb" : "chat.pb")
            try batch.serializedData().write(to: file)
        }
        let traceID = generation.traceID.map { String(format: "%02x", $0) }.joined()
        print("DISCONNECT_OTLP_VERIFIED api=\(responses ? "responses" : "chat") trace=\(traceID) domain=NSURLErrorDomain code=-1005 stage=streaming_output model=disconnect-verification-model parent_error=true")
    }

    @MainActor
    @Test func http530IsRecordedAndFailedOTLPBatchIsRetriedWithNextGeneration() async throws {
        let receiver = try FailureReceiver()
        defer { receiver.stop() }
        let baseURL = try await receiver.baseURL()
        let local = FailureRecordingTelemetry()
        let router = TelemetryRouter(localTelemetry: local)
        router.configure(.init(endpoint: baseURL.appendingPathComponent("v1/traces")))
        let viewModel = ChatViewModel(
            llm: OpenAIResponsesClient(baseURL: baseURL.appendingPathComponent("v1"), apiKey: "test-only"),
            toolExecutor: StubToolExecutor(), tools: [], model: "verification-model", systemPrompt: nil,
            traceSink: router, telemetry: router
        )

        // 画像と同じ HTTP 530 + Cloudflare HTML を URLSession に実際に返す。
        await viewModel.send("failure verification")
        #expect(viewModel.errorMessage?.contains("HTTP 530") == true)
        let event = try #require(local.errors().first)
        #expect(event["error"]?.contains("530") == true)
        #expect(event["error"]?.contains("Cloudflare Tunnel error") == true)
        #expect(event["generation_id"] != nil)

        let first = try await receiver.request(number: 0)
        let firstSpans = first.resourceSpans.flatMap(\.scopeSpans).flatMap(\.spans)
        let generation = try #require(firstSpans.first { $0.name == "llm.generation" })
        #expect(generation.status.code == .error)
        #expect(generation.status.message.contains("530"))
        let attributes = Dictionary(uniqueKeysWithValues: generation.attributes.map { ($0.key, $0.value.stringValue) })
        #expect(attributes["error"]?.contains("Cloudflare Tunnel error") == true)
        #expect(attributes["generation_id"] == event["generation_id"])
        // 欠如は観測に留める。将来HTTP属性を追加しても、この配送保証を壊す変更とはしない。
        print("TELEMETRY_ATTRIBUTES http.response.status_code=\(attributes["http.response.status_code"] ?? "absent") error.type=\(attributes["error.type"] ?? "absent")")

        // 受信側は初回 batch を 503 で拒否する。処理完了を待って次の generation を発生させる。
        // 現SDKの再送は次の export に同梱されるため、無操作時の自動再送を仮定しない。
        try await Task.sleep(for: .milliseconds(300))
        await viewModel.send("retry delivery verification")
        let second = try await receiver.request(number: 1)
        let secondSpans = second.resourceSpans.flatMap(\.scopeSpans).flatMap(\.spans)
        #expect(secondSpans.contains { $0.spanID == generation.spanID && $0.traceID == generation.traceID })
        #expect(secondSpans.filter { $0.name == "llm.generation" && $0.status.code == .error }.count == 2)
        print("TELEMETRY_VERIFIED HTTP=530 local_error_events=\(local.errors().count) first_spans=\(firstSpans.count) second_spans=\(secondSpans.count) retried_original_span=true")
    }
}

private final class FailureRecordingTelemetry: TelemetryPort, @unchecked Sendable {
    private let lock = NSLock()
    private var recordedErrors: [[String: String]] = []

    func event(_ name: String, fields: [String: String], level: TelemetryLevel) {
        OSLogTelemetry().event(name, fields: fields, level: level)
        lock.lock(); defer { lock.unlock() }
        if name == "llm.generation.error", level == .error { recordedErrors.append(fields) }
    }

    func errors() -> [[String: String]] {
        lock.lock(); defer { lock.unlock() }
        return recordedErrors
    }
}

// ephemeral port と一時ディレクトリで並行検証との競合を避ける。Python 標準ライブラリだけを
// 使い、追加 Collector や新しい永続化構成を持ち込まない。受信データは終了時に削除する。
final class FailureReceiver {
    private let directory: URL
    private let process = Process()

    init(disconnect: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", "-c", Self.script, directory.path, disconnect ? "disconnect" : "http530"]
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
        let data = try await waitForFile("port")
        let port = try #require(String(data: data, encoding: .utf8))
        return try #require(URL(string: "http://127.0.0.1:\(port)"))
    }

    func request(number: Int) async throws -> Opentelemetry_Proto_Collector_Trace_V1_ExportTraceServiceRequest {
        try await .init(serializedBytes: waitForFile("\(number).pb"))
    }

    private func waitForFile(_ name: String) async throws -> Data {
        // SDK batch delay は既定5秒。25秒以内の実受信を要求し、固定sleepだけで成功扱いしない。
        for _ in 0 ..< 250 {
            if let data = try? Data(contentsOf: directory.appendingPathComponent(name)) { return data }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }

    private static let script = #"""
import gzip, http.server, json, pathlib, sys, time
root = pathlib.Path(sys.argv[1])
disconnect = sys.argv[2] == 'disconnect'
class Handler(http.server.BaseHTTPRequestHandler):
    count = 0
    def log_message(self, *args): pass
    def do_POST(self):
        data = self.rfile.read(int(self.headers['Content-Length']))
        if self.path == '/v1/traces':
            if self.headers.get('Content-Encoding') == 'gzip': data = gzip.decompress(data)
            number = Handler.count
            Handler.count += 1
            temp = root / 'receiving.tmp'
            temp.write_bytes(data)
            temp.replace(root / f'{number}.pb')
            self.send_response(503 if number == 0 and not disconnect else 200)
            self.send_header('Content-Length', '0')
            self.end_headers()
        elif disconnect:
            if self.path.endswith('/responses'):
                value = {'type': 'response.output_text.delta', 'delta': 'probe'}
            else:
                value = {'id': 'local', 'object': 'chat.completion.chunk', 'created': 0,
                         'model': 'disconnect-verification-model',
                         'choices': [{'index': 0, 'delta': {'content': 'probe'}, 'finish_reason': None}]}
            data = ('data: ' + json.dumps(value) + '\n\n').encode()
            self.send_response(200)
            self.send_header('Content-Type', 'text/event-stream')
            self.send_header('Content-Length', str(len(data) + 1024))
            self.end_headers()
            self.wfile.write(data)
            self.wfile.flush()
            # 完了前にbodyを閉じる。delta配送の時間を確保し段階の観測を安定させる。
            time.sleep(0.2)
            self.close_connection = True
        else:
            data = b'<!doctype html><title>Cloudflare Tunnel error</title><p>Error 1033</p>'
            self.send_response(530)
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
(root / 'port').write_text(str(server.server_port))
server.serve_forever()
"""#
}

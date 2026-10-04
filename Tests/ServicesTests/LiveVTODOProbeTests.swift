// Opt-in service probe: actual MCP/LLM/OTLP, without launching or manipulating a device.
// Normal test runs do not read credentials or send network requests. Private evidence stays in .build.
// To opt in, set MCPHOST_LIVE_VTODO=1 and supply MCPHOST_LIVE_MCP_URL and MCPHOST_LIVE_MCP_TOKEN,
// MCPHOST_LIVE_CALENDAR_ID, MCPHOST_LLM_BASEURL/KEY/MODEL, MCPHOST_LIVE_OTLP_URL/AUTH.
// Run swift test --filter LiveVTODOProbeTests. This verifies service logic, not device UX or OAuth UI.
// MCPHOST_LIVE_CATALOG=full exposes the real model-visible catalog; default is list-todos alone.
// MCPHOST_LIVE_DEADLINE_SECONDS can bound a comparison turn (default 180).
import Foundation
import MCP
import Testing
@testable import Kernel
@testable import Services

private final class ProbeLLM: LLMClient, @unchecked Sendable {
    let client: OpenAICompatClient
    private(set) var requests: [ChatCompletionRequest] = []
    private(set) var events: [String] = []

    init(client: OpenAICompatClient) { self.client = client }

    // ChatViewModel calls this serially on MainActor; tool calls alone are concurrent.
    func stream(_ request: ChatCompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        requests.append(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try saveProbeEvidence(JSONValue(encoding: requests), name: "requests")
                    FileHandle.standardError.write(Data(
                        "LIVE_VTODO request=\(requests.count) bytes=\(try JSONEncoder().encode(request).count)\n".utf8
                    ))
                    for try await event in client.stream(request) {
                        if case .responseStarted = event { try record("responseStarted") }
                        if case .outputStarted = event { try record("outputStarted") }
                        if case .completed = event { try record("completed") }
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func record(_ event: String) throws {
        events.append(event)
        try saveProbeEvidence(JSONValue(encoding: events), name: "events")
        FileHandle.standardError.write(Data("LIVE_VTODO llm=\(event)\n".utf8))
    }
}

private actor ProbeTools: MCPToolExecuting {
    let proxy: AppsServerProxy
    let calendarID: String
    private(set) var results: [JSONValue] = []

    init(proxy: AppsServerProxy, calendarID: String) {
        self.proxy = proxy
        self.calendarID = calendarID
    }

    func callTool(name: String, arguments: JSONValue?) async throws -> JSONValue {
        guard name == "list-todos", arguments?["calendarId"]?.stringValue == calendarID else {
            throw ProbeError.unexpectedTool
        }
        let result = try await proxy.callTool(name: name, arguments: arguments)
        results.append(result)
        try saveProbeEvidence(.array(results), name: "tools")
        return result
    }
}

private enum ProbeError: Error { case missingEnvironment(String), unexpectedTool }

private struct ProbeTelemetry: TelemetryPort {
    let service: OpenTelemetryService

    func event(_ name: String, fields: [String: String], level: TelemetryLevel) {
        service.event(name, fields: fields.merging([
            "deployment.environment.name": "verification",
            "verification.kind": "agent-service-probe"
        ]) { _, new in new }, level: level)
    }

    func correlationContext(for operationID: String) -> String? {
        service.correlationContext(for: operationID)
    }
}

@Suite struct LiveVTODOProbeTests {
    private func required(_ key: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else {
            throw ProbeError.missingEnvironment(key)
        }
        return value
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MCPHOST_LIVE_VTODO"] == "1"))
    @MainActor func actualVTODOFeedsFinalAnswerAndOTLP() async throws {
        let serverURL = try #require(URL(string: required("MCPHOST_LIVE_MCP_URL")))
        let client = try await connect(serverURL: serverURL)
        FileHandle.standardError.write(Data("LIVE_VTODO connected\n".utf8))
        let discovered = try await client.listTools().tools
        let fullCatalog = ProcessInfo.processInfo.environment["MCPHOST_LIVE_CATALOG"] == "full"
        let available = fullCatalog ? discovered : discovered.filter { $0.name == "list-todos" }
        let definitions = try toolDefinitions(from: available)
        #expect(!definitions.isEmpty)
        #expect(fullCatalog || definitions.count == 1)
        let proxy = AppsServerProxy(client: client)
        let calendarID = try required("MCPHOST_LIVE_CALENDAR_ID")
        let tools = ProbeTools(proxy: proxy, calendarID: calendarID)
        let llm = try makeLLM()
        let service = try makeTelemetry()
        let sessionID = UUID().uuidString
        let viewModel = try ChatViewModel(
            llm: llm, toolExecutor: tools, tools: definitions, model: required("MCPHOST_LLM_MODEL"),
            reasoningEffort: "low", systemPrompt: "Use the real tool result. Do not invent tasks.",
            traceSink: service, telemetry: ProbeTelemetry(service: service), sessionId: sessionID,
            serverURL: serverURL
        )
        FileHandle.standardError.write(Data("LIVE_VTODO sending\n".utf8))
        await sendWithDeadline(viewModel: viewModel, calendarID: calendarID)
        FileHandle.standardError.write(Data("LIVE_VTODO settled\n".utf8))
        let results = await tools.results
        let output = viewModel.turns.last?.text ?? ""
        let titles = results.first?["structuredContent"]?["tasks"]?.arrayValue?.compactMap {
            $0["title"]?.stringValue
        } ?? []
        let toolInputs = llm.requests.dropFirst().flatMap { $0.messages }.filter { $0.role == .tool }
        let allInInput = titles.allSatisfy { title in toolInputs.contains { $0.content?.contains(title) == true } }
        let allInOutput = titles.prefix(2).allSatisfy { output.contains($0) }
        try saveEvidence(sessionID: sessionID, results: results, llm: llm, viewModel: viewModel)
        print("LIVE_VTODO session=\(sessionID) tasks=\(titles.count) calls=\(results.count) " +
              "catalog=\(definitions.count) requests=\(llm.requests.count) inputMatch=\(allInInput) outputMatch=\(allInOutput)")
        #expect(viewModel.errorMessage == nil)
        #expect(!titles.isEmpty)
        #expect(!toolInputs.isEmpty)
        #expect(allInInput)
        #expect(allInOutput)
        #expect(viewModel.turns.last?.telemetryContext != nil)
        // The shipping exporter batches asynchronously; its actual persisted spans are checked separately.
        try await Task.sleep(for: .seconds(8))
        await client.disconnect()
    }
    @MainActor private func sendWithDeadline(viewModel: ChatViewModel, calendarID: String) async {
        let send = Task { await viewModel.send(
            "検証用のVTODOリスト \(calendarID) をlist-todosで取得してください。" +
                "timeZoneはAsia/Tokyo。返却順の最初の2件のタイトルだけをそのまま答えてください。" +
                "作成・変更・削除はせず、この1リストだけ確認してください。"
        ) }
        let configured = ProcessInfo.processInfo.environment["MCPHOST_LIVE_DEADLINE_SECONDS"] ?? "180"
        let deadlineSeconds = Double(configured) ?? 180
        let deadline = Task {
            try await Task.sleep(for: .seconds(deadlineSeconds))
            send.cancel()
        }
        await send.value
        deadline.cancel()
    }

    private func makeTelemetry() throws -> OpenTelemetryService {
        return try OpenTelemetryService(configuration: .init(
            endpoint: #require(URL(string: required("MCPHOST_LIVE_OTLP_URL"))),
            headers: [
                ("Authorization", required("MCPHOST_LIVE_OTLP_AUTH")), ("x-langfuse-ingestion-version", "4")
            ], resourceAttributes: [
                "deployment.environment.name": "verification",
                "verification.catalog": ProcessInfo.processInfo.environment["MCPHOST_LIVE_CATALOG"] ?? "single"
            ]
        ))
    }

    private func makeLLM() throws -> ProbeLLM {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        configuration.protocolClasses = [LiveProbeStreamRecorder.self]
        return try ProbeLLM(client: OpenAICompatClient(
            baseURL: #require(URL(string: required("MCPHOST_LLM_BASEURL"))),
            apiKey: required("MCPHOST_LLM_KEY"), urlSession: URLSession(configuration: configuration)
        ))
    }

    private func connect(serverURL: URL) async throws -> Client {
        let token = try required("MCPHOST_LIVE_MCP_TOKEN")
        let client = Client(name: "swift-live-service-probe", version: "1")
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        let transport = HTTPClientTransport(
            endpoint: serverURL, configuration: configuration, requestModifier: { request in
            var request = request
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("swift-live-service-verification/1.0", forHTTPHeaderField: "User-Agent")
            return request
        })
        _ = try await client.connect(transport: transport)
        return client
    }

    @MainActor private func saveEvidence(
        sessionID: String, results: [JSONValue], llm: ProbeLLM, viewModel: ChatViewModel
    ) throws {
        let evidence: JSONValue = .object([
            "sessionID": .string(sessionID), "model": .string(try required("MCPHOST_LLM_MODEL")),
            "results": .array(results), "requests": try JSONValue(encoding: llm.requests),
            "events": try JSONValue(encoding: llm.events),
            "session": try JSONValue(encoding: viewModel.currentSession),
            "error": viewModel.errorMessage.map(JSONValue.string) ?? .null
        ])
        try saveProbeEvidence(evidence, name: sessionID)
    }
}

private func saveProbeEvidence(_ evidence: JSONValue, name: String) throws {
    let directory = URL(fileURLWithPath: ".build/live-vtodo-probe", isDirectory: true)
    try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    let path = directory.appendingPathComponent("\(name)-\(UUID().uuidString).json")
    try JSONEncoder().encode(evidence).write(to: path, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
}

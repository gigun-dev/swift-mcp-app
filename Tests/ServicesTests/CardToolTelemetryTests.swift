import Foundation
import Kernel
import Testing
@testable import Services

@Suite struct CardToolTelemetryTests {
    @Test(arguments: ["success", "isError", "transport", "cancelled"])
    func completionPreservesResponseAndExcludesPayload(outcome: String) async throws {
        let recorder = CardToolRecorder()
        let transport = MockTransport()
        let proxy = CardToolProxy(outcome: outcome)
        let dispatcher = AppsBridgePassthroughDispatcher(
            transport: transport, proxy: proxy, onCardToolCall: nil,
            telemetry: recorder
        )
        await dispatcher.dispatch(method: AppsMethod.toolsCall, id: .int(42), params: params)
        try await wait { recorder.finished.count == 1 && !transport.sentRawJSON.isEmpty }
        let fields = try #require(recorder.finished.first)
        #expect(fields["outcome"] == outcome)
        #expect(recorder.errors == (outcome == "transport" || outcome == "isError" ? 1 : 0))
        #expect(fields["bridge.request_id"] == "42")
        #expect(fields["mcp.tool.name"] == "update-todo")
        #expect(fields["operation_id"] == recorder.started.first?["operation_id"])
        #expect(Int(fields["duration_ms"] ?? "").map { $0 >= 0 } == true)
        #expect(!String(describing: fields).contains("private-payload"))
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: Data(transport.sentRawJSON[0].utf8))
        if outcome == "success" || outcome == "isError" {
            #expect(response.result == proxy.result)
        } else {
            #expect(response.error?.code == -32603)
            #expect(fields["error.domain"] == NSURLErrorDomain)
            #expect(fields["error.code"] == (outcome == "transport" ? "-1005" : "-999"))
        }
        await dispatcher.close()
        #expect(recorder.finished.count == 1)
    }

    @Test func closeEndsPendingOperationEvenWhenProxyIgnoresCancellation() async throws {
        let recorder = CardToolRecorder()
        let proxy = CardToolGate()
        let transport = MockTransport()
        let dispatcher = AppsBridgePassthroughDispatcher(
            transport: transport, proxy: proxy, onCardToolCall: nil,
            telemetry: recorder
        )
        await dispatcher.dispatch(method: AppsMethod.toolsCall, id: .string("bridge-42"), params: params)
        try await wait { await proxy.waiting }
        await dispatcher.close()
        #expect(recorder.finished.count == 1)
        #expect(recorder.finished.first?["outcome"] == "cancelled")
        await proxy.release()
        try await wait { await proxy.returned }
        await dispatcher.close()
        #expect(recorder.finished.count == 1)
        #expect(transport.sentRawJSON.isEmpty)
    }

    @Test func immediateCloseDoesNotLeaveStartedOperation() async {
        let recorder = CardToolRecorder()
        let dispatcher = AppsBridgePassthroughDispatcher(
            transport: MockTransport(), proxy: CardToolProxy(outcome: "success"), onCardToolCall: nil,
            telemetry: recorder
        )
        await dispatcher.dispatch(method: AppsMethod.toolsCall, id: nil, params: params)
        await dispatcher.close()
        #expect(recorder.started.count == 1)
        #expect(recorder.finished.count == 1)
    }

    @Test(arguments: ["success", "isError", "transport", "cancelled"])
    func exporterProducesCardToolPayload(outcome: String) async throws {
        let receiver = try FailureReceiver()
        defer { receiver.stop() }
        let base = try await receiver.baseURL()
        let telemetry = OpenTelemetryService(configuration: .init(endpoint: base.appendingPathComponent("v1/traces")))
        let dispatcher = AppsBridgePassthroughDispatcher(
            transport: MockTransport(), proxy: CardToolProxy(outcome: outcome), onCardToolCall: nil,
            telemetry: telemetry
        )
        await dispatcher.dispatch(method: AppsMethod.toolsCall, id: .int(42), params: params)
        let batch = try await receiver.request(number: 0)
        if let directory = ProcessInfo.processInfo.environment["MCPHOST_VERIFY_OTLP_DIRECTORY"] {
            let path = URL(fileURLWithPath: directory).appendingPathComponent("card-tool-\(outcome).pb")
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try batch.serializedData().write(to: path)
        }
        let spans = batch.resourceSpans.flatMap(\.scopeSpans).flatMap(\.spans)
        let span = try #require(spans.first { $0.name == "card.tool" })
        let fields = Dictionary(uniqueKeysWithValues: span.attributes.map { ($0.key, $0.value.stringValue) })
        if outcome == "cancelled" {
            #expect(span.status.code.rawValue == 0)
        } else {
            #expect(span.status.code == (outcome == "success" ? .ok : .error))
        }
        #expect(span.parentSpanID.isEmpty)
        #expect(span.endTimeUnixNano >= span.startTimeUnixNano)
        #expect(fields["outcome"] == outcome)
        if outcome == "transport" { #expect(fields["error.code"] == "-1005") }
        if outcome == "cancelled" { #expect(fields["error.code"] == "-999") }
        #expect(fields["bridge.request_id"] == "42")
        #expect(fields["operation_id"] != nil)
        #expect(fields["mcp.tool.name"] == "update-todo")
        #expect(!String(describing: fields).contains("private-payload"))
        await dispatcher.close()
    }

    private var params: JSONValue {
        .object(["name": .string("update-todo"), "arguments": .object(["title": .string("private-payload")])])
    }

    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0 ..< 200 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("Card operation did not complete")
    }
}

private final class CardToolRecorder: TelemetryPort, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [(String, [String: String])] = []
    private var errorCount = 0
    var errors: Int { lock.withLock { errorCount } }
    var started: [[String: String]] { lock.withLock { events.filter { $0.0 == "card.tool.started" }.map(\.1) } }
    var finished: [[String: String]] { lock.withLock { events.filter { $0.0 == "card.tool.finished" }.map(\.1) } }
    func event(_ name: String, fields: [String: String], level: TelemetryLevel) {
        lock.withLock {
            events.append((name, fields))
            if level == .error { errorCount += 1 }
        }
    }
}

private struct CardToolProxy: AppsServerProxying {
    let outcome: String
    var result: JSONValue { .object(["isError": .bool(outcome == "isError"), "content": .string("private-payload")]) }
    func passthroughToolsCall(params: JSONValue?) async throws -> JSONValue {
        if outcome == "transport" { throw URLError(.networkConnectionLost) }
        if outcome == "cancelled" { throw URLError(.cancelled) }
        return result
    }
    func passthroughResourcesRead(params: JSONValue?) async throws -> JSONValue { .object([:]) }
}

private actor CardToolGate: AppsServerProxying {
    private var continuation: CheckedContinuation<Void, Never>?
    var waiting: Bool { continuation != nil }
    private(set) var returned = false
    func passthroughToolsCall(params: JSONValue?) async throws -> JSONValue {
        await withCheckedContinuation { continuation = $0 }
        returned = true
        return .object([:])
    }
    func release() { continuation?.resume(); continuation = nil }
    func passthroughResourcesRead(params: JSONValue?) async throws -> JSONValue { .object([:]) }
}

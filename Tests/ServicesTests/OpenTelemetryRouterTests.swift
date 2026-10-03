import Foundation
import Kernel
import Services
import Testing

@Test("OTLP未設定でもOSLog相当のlocal sinkへイベントを転送する")
func telemetryRouterKeepsLocalTelemetryWithoutRemoteConfiguration() {
    let local = RecordingTelemetry()
    let trace = RecordingTraceSink()
    let router = TelemetryRouter(localTelemetry: local, localTrace: trace)

    router.event("chat.feedback", fields: ["rating": "positive"], level: .info)
    router.emit(.turnStarted(chatId: "chat", turnId: "turn", model: "model"))

    #expect(local.snapshot() == ["chat.feedback:positive"])
    #expect(trace.count == 1)
}

private final class RecordingTelemetry: TelemetryPort, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func event(_ name: String, fields: [String: String], level: TelemetryLevel) {
        lock.lock()
        values.append("\(name):\(fields["rating"] ?? "")")
        lock.unlock()
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

private final class RecordingTraceSink: TraceSink, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ChatTraceEvent] = []
    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return values.count
    }

    func emit(_ event: ChatTraceEvent) {
        lock.lock(); values.append(event); lock.unlock()
    }
}

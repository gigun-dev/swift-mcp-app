import Foundation
import Kernel
import OSLog

/// ID相関で順不同に処理できるMCP passthrough requestをSessionの直列状態機械から分離する。
actor AppsBridgePassthroughDispatcher {
    private let transport: any AppsBridgeTransport
    private let proxy: any AppsServerProxying
    private let onCardToolCall: (@Sendable () async -> Void)?
    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "appspassthrough")
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var isClosed = false
    private let telemetry: any TelemetryPort
    private var operations: [UUID: (fields: [String: String], start: ContinuousClock.Instant)] = [:]

    init(
        transport: any AppsBridgeTransport,
        proxy: any AppsServerProxying,
        onCardToolCall: (@Sendable () async -> Void)?,
        telemetry: any TelemetryPort = NullTelemetry()
    ) {
        self.transport = transport
        self.proxy = proxy
        self.onCardToolCall = onCardToolCall
        self.telemetry = telemetry
    }

    func dispatch(method: String, id: RequestID?, params: JSONValue?) {
        guard !isClosed else { return }
        if method == AppsMethod.toolsCall, let onCardToolCall {
            Task { await onCardToolCall() }
        }
        let key = UUID()
        if method == AppsMethod.toolsCall {
            var fields = ["operation_id": key.uuidString, "mcp.tool.name": params?["name"]?.stringValue ?? ""]
            switch id {
            case .string(let value): fields["bridge.request_id"] = value
            case .int(let value): fields["bridge.request_id"] = String(value)
            case nil: break
            }
            operations[key] = (fields, .now)
            telemetry.event("card.tool.started", fields: fields, level: .notice)
        }
        tasks[key] = Task { [weak self] in
            await self?.handle(method: method, id: id, params: params, operationID: key)
            await self?.remove(key)
        }
    }

    func close() {
        isClosed = true
        for key in Array(operations.keys) { finish(key, outcome: "cancelled") }
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    private func handle(method: String, id: RequestID?, params: JSONValue?, operationID: UUID) async {
        guard !isClosed, !Task.isCancelled else {
            finish(operationID, outcome: "cancelled")
            return
        }
        switch method {
        case AppsMethod.toolsCall:
            _ = await proxyRequest(id: id, label: "tools/call", operationID: operationID) {
                try await self.proxy.passthroughToolsCall(params: params)
            }
        case AppsMethod.resourcesRead:
            _ = await proxyRequest(id: id, label: "resources/read") {
                try await self.proxy.passthroughResourcesRead(params: params)
            }
        case AppsMethod.ping:
            if let id { await transport.deliver(response: JSONRPCResponse(id: id, result: .object([:]))) }
        default:
            await rejectUnknown(method: method, id: id)
        }
    }

    private func proxyRequest(
        id: RequestID?,
        label: String,
        operationID: UUID? = nil,
        work: @Sendable () async throws -> JSONValue
    ) async -> Bool {
        do {
            let result = try await work()
            if let operationID {
                let outcome = result["isError"]?.boolValue == true ? "isError" : "success"
                finish(operationID, outcome: Task.isCancelled || isClosed ? "cancelled" : outcome)
            }
            guard !isClosed else { return false }
            if let id {
                await transport.deliver(response: JSONRPCResponse(id: id, result: result))
                logger.notice("\(label, privacy: .public) 素通し応答済み")
            }
            return result["isError"]?.boolValue != true
        } catch {
            let nsError = error as NSError
            let cancelled = Task.isCancelled || isClosed || error is CancellationError
                || (nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled)
            if let operationID {
                finish(operationID, outcome: cancelled ? "cancelled" : "transport", error: nsError)
            }
            if cancelled {
                logger.notice("\(label, privacy: .public) 素通しcancelled")
            } else {
                logger.error("\(label, privacy: .public) 素通し失敗 domain=\(nsError.domain, privacy: .public) code=\(nsError.code)")
            }
            guard !isClosed else { return false }
            guard let id else { return false }
            let rpcError = JSONRPCError(code: -32603, message: "\(label) 失敗: \(error)")
            await transport.deliver(response: JSONRPCResponse(id: id, error: rpcError))
            return false
        }
    }

    // Remove before emitting: close and a late proxy completion must end the same operation once.
    private func finish(_ key: UUID, outcome: String, error: NSError? = nil) {
        guard let operation = operations.removeValue(forKey: key) else { return }
        var fields = operation.fields
        let elapsed = operation.start.duration(to: .now).components
        fields["duration_ms"] = String(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
        fields["outcome"] = outcome
        if let error {
            fields["error.domain"] = error.domain
            fields["error.code"] = String(error.code)
            fields["error.type"] = "\(error.domain):\(error.code)"
        }
        let level: TelemetryLevel = outcome == "transport" || outcome == "isError" ? .error : .notice
        telemetry.event("card.tool.finished", fields: fields, level: level)
    }

    private func rejectUnknown(method: String, id: RequestID?) async {
        guard let id else {
            logger.notice("未知 notification method=\(method, privacy: .public)(黙殺)")
            return
        }
        let error = JSONRPCError.methodNotFound(method)
        await transport.deliver(response: JSONRPCResponse(id: id, error: error))
    }

    private func remove(_ key: UUID) {
        tasks[key] = nil
    }
}

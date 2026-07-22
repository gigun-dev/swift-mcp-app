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

    init(
        transport: any AppsBridgeTransport,
        proxy: any AppsServerProxying,
        onCardToolCall: (@Sendable () async -> Void)?
    ) {
        self.transport = transport
        self.proxy = proxy
        self.onCardToolCall = onCardToolCall
    }

    func dispatch(method: String, id: RequestID?, params: JSONValue?) {
        guard !isClosed else { return }
        if method == AppsMethod.toolsCall, let onCardToolCall {
            Task { await onCardToolCall() }
        }
        let key = UUID()
        tasks[key] = Task { [weak self] in
            await self?.handle(method: method, id: id, params: params)
            await self?.remove(key)
        }
    }

    func close() {
        isClosed = true
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    private func handle(method: String, id: RequestID?, params: JSONValue?) async {
        switch method {
        case AppsMethod.toolsCall:
            await proxyRequest(id: id, label: "tools/call") {
                try await self.proxy.passthroughToolsCall(params: params)
            }
        case AppsMethod.resourcesRead:
            await proxyRequest(id: id, label: "resources/read") {
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
        work: @Sendable () async throws -> JSONValue
    ) async {
        do {
            let result = try await work()
            guard !isClosed else { return }
            if let id {
                await transport.deliver(response: JSONRPCResponse(id: id, result: result))
                logger.notice("\(label, privacy: .public) 素通し応答済み")
            }
        } catch {
            logger.error("\(label, privacy: .public) 素通し失敗: \(String(reflecting: error), privacy: .public)")
            guard !isClosed, let id else { return }
            let rpcError = JSONRPCError(code: -32603, message: "\(label) 失敗: \(error)")
            await transport.deliver(response: JSONRPCResponse(id: id, error: rpcError))
        }
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

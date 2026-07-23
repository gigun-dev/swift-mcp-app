import Foundation
import Kernel
import OSLog

/// ID相関で順不同に処理できるMCP passthrough requestをSessionの直列状態機械から分離する。
actor AppsBridgePassthroughDispatcher {
    private let transport: any AppsBridgeTransport
    private let proxy: any AppsServerProxying
    private let onCardToolCall: (@Sendable () async -> Void)?
    private let shouldObserveCardToolCall: (@Sendable () async -> Bool)?
    private let onCardToolCallCompleted: (@Sendable (_ succeeded: Bool) async -> Void)?
    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "appspassthrough")
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var isClosed = false

    init(
        transport: any AppsBridgeTransport,
        proxy: any AppsServerProxying,
        onCardToolCall: (@Sendable () async -> Void)?,
        shouldObserveCardToolCall: (@Sendable () async -> Bool)?,
        onCardToolCallCompleted: (@Sendable (_ succeeded: Bool) async -> Void)?
    ) {
        self.transport = transport
        self.proxy = proxy
        self.onCardToolCall = onCardToolCall
        self.shouldObserveCardToolCall = shouldObserveCardToolCall
        self.onCardToolCallCompleted = onCardToolCallCompleted
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
            // result配送前に開始済みの自動callが遅れて完了しても、履歴gateのrevalidation成功には
            // 数えない。requestごとの開始時点で観測対象かを固定し、並行call同士を取り違えない。
            let shouldReportCompletion = await shouldObserveCardToolCall?() ?? true
            let succeeded = await proxyRequest(id: id, label: "tools/call") {
                try await self.proxy.passthroughToolsCall(params: params)
            }
            if shouldReportCompletion, !isClosed, let onCardToolCallCompleted {
                await onCardToolCallCompleted(succeeded)
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
        work: @Sendable () async throws -> JSONValue
    ) async -> Bool {
        do {
            let result = try await work()
            guard !isClosed else { return false }
            if let id {
                await transport.deliver(response: JSONRPCResponse(id: id, result: result))
                logger.notice("\(label, privacy: .public) 素通し応答済み")
            }
            // MCP tools/call はtransport上の成功応答でも CallToolResult.isError=true を返し得る。
            // 履歴revalidationのunlockは「現在状態を取得できた」場合だけなので、これも失敗扱いにする。
            return result["isError"]?.boolValue != true
        } catch {
            logger.error("\(label, privacy: .public) 素通し失敗: \(String(reflecting: error), privacy: .public)")
            guard !isClosed else { return false }
            guard let id else { return false }
            let rpcError = JSONRPCError(code: -32603, message: "\(label) 失敗: \(error)")
            await transport.deliver(response: JSONRPCResponse(id: id, error: rpcError))
            return false
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

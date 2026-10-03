import Foundation
import MCP

// OAuth discovery/DCR/PKCE/rotationはSDKへ委譲する。標準authorizer境界で保存確定だけを補い、
// SDKの503/timeout前clearによって次回再認可になる欠落を埋める。
final class PreservingOAuthAuthorizer: HTTPClientAuthorizer, @unchecked Sendable {
    private let underlying: any HTTPClientAuthorizer
    private let storage: OAuthTransactionalStorage

    init(configuration: OAuthConfiguration, store: OAuthTokenStore) {
        let storage = OAuthTransactionalStorage(store: store)
        self.storage = storage
        self.underlying = OAuthAuthorizer(configuration: configuration, tokenStorage: storage)
    }

    // 偽authorizerで世代競合を決定的に検証する内部口。本番も同じSDK向けstorageを渡す。
    init(underlying: any HTTPClientAuthorizer, storage: OAuthTransactionalStorage) {
        self.underlying = underlying
        self.storage = storage
    }

    var maxAuthorizationAttempts: Int { underlying.maxAuthorizationAttempts }
    func validateEndpointSecurity(for endpoint: URL) throws { try underlying.validateEndpointSecurity(for: endpoint) }
    func authorizationHeader(for endpoint: URL) -> String? { underlying.authorizationHeader(for: endpoint) }

    func handleChallenge(
        statusCode: Int, headers: [String: String], endpoint: URL,
        operationKey: String? = nil, session: URLSession
    ) async throws -> Bool {
        try await transaction {
            try await self.underlying.handleChallenge(
                statusCode: statusCode, headers: headers, endpoint: endpoint,
                operationKey: operationKey, session: session)
        }
    }

    func prepareAuthorization(for endpoint: URL, session: URLSession) async throws {
        _ = try await transaction {
            try await self.underlying.prepareAuthorization(for: endpoint, session: session)
            return true
        }
    }

    private func transaction(_ operation: () async throws -> Bool) async throws -> Bool {
        await storage.store.mutationGate.acquire()
        defer { storage.store.mutationGate.release() }
        try Task.checkCancellation()
        storage.begin()
        let result: Bool
        do {
            result = try await operation()
        } catch {
            // SDKは4xxを内部でfalseへ畳んで再認可へ進む。既存の再認可clearを維持し、
            // 外にthrowされる一時HTTP/通信失敗だけ保存をrollbackする。
            try storage.finish(commit: !Self.isTransient(error))
            throw error
        }
        if Task.isCancelled {
            try storage.finish(commit: false)
            throw CancellationError()
        }
        try storage.finish(commit: true)
        return result
    }

    static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if (error as NSError).domain == NSURLErrorDomain { return true }
        if case OAuthAuthorizationError.tokenRequestFailed(let status, _) = error {
            return status >= 500 || status == -1
        }
        // discoveryはSDKがHTTP statusを捨てるので原因を断定しない。認可を進めず旧tokenを
        // 保持してthrowし、再試行時にdiscoverし直せる状態を残す。
        if case OAuthAuthorizationError.metadataDiscoveryFailed = error { return true }
        if case OAuthAuthorizationError.authorizationServerMetadataDiscoveryFailed = error { return true }
        return false
    }
}

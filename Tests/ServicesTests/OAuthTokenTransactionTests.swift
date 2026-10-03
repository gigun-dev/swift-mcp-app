import Foundation
import MCP
import Testing

@testable import Services

// networkの速度ではなく、clear/saveとSDK呼出の順序を決定的に作る。
// pauseは親の操作が終わるまで解除されず、sleepで競合の再現を賭けない。
private actor OAuthTestPause {
    private var entered = false
    private var observers: [CheckedContinuation<Void, Never>] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func stop() async {
        entered = true
        observers.forEach { $0.resume() }
        observers = []
        await withCheckedContinuation { continuation = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func resume() { continuation?.resume(); continuation = nil }
}

private final class PausedOAuthAuthorizer: HTTPClientAuthorizer, @unchecked Sendable {
    let storage: OAuthTransactionalStorage
    let pause = OAuthTestPause()
    let outcome: String
    let next: String
    private(set) var observedRefresh: String?
    init(storage: OAuthTransactionalStorage, outcome: String, next: String = "new") {
        self.storage = storage
        self.outcome = outcome
        self.next = next
    }
    var maxAuthorizationAttempts: Int { 1 }
    func validateEndpointSecurity(for endpoint: URL) throws {}
    func authorizationHeader(for endpoint: URL) -> String? { storage.load().map { "Bearer \($0.value)" } }
    func handleChallenge(
        statusCode: Int, headers: [String: String], endpoint: URL, operationKey: String?, session: URLSession
    ) async throws -> Bool {
        observedRefresh = storage.load()?.refreshToken
        storage.clear()
        await pause.stop()
        if outcome == "503" { throw OAuthAuthorizationError.tokenRequestFailed(statusCode: 503, oauthError: nil) }
        if outcome == "timeout" { throw URLError(.timedOut) }
        storage.save(fixtureToken(next))
        return true
    }
}

private func fixtureToken(_ value: String) -> OAuthAccessToken {
    .init(value: value, tokenType: "Bearer", expiresAt: nil, scopes: [], authorizationServer: nil,
          refreshToken: "refresh-\(value)", clientID: "fixture-client")
}

@Suite(.serialized)
struct OAuthTokenTransactionTests {
    private let endpoint = URL(string: "https://fixture.example/mcp")!
    private func execute(_ authorizer: PreservingOAuthAuthorizer) async throws -> Bool {
        try await authorizer.handleChallenge(statusCode: 401, headers: [:], endpoint: endpoint, session: .shared)
    }

    @Test("明示clearを成功commitも失敗rollbackも復活させない", arguments: ["success", "503", "timeout"])
    func explicitClearWins(outcome: String) async throws {
        let store = OAuthTokenStore(storage: InMemoryTokenStorage())
        store.save(fixtureToken("old"))
        let transaction = OAuthTransactionalStorage(store: store)
        let sdk = PausedOAuthAuthorizer(storage: transaction, outcome: outcome)
        let authorizer = PreservingOAuthAuthorizer(underlying: sdk, storage: transaction)
        let task = Task { try await execute(authorizer) }
        await sdk.pause.waitUntilEntered()
        // ServerRegistry.remove/logoutが通る共有storeの明示clearを、SDK await中へ入れる。
        store.clear()
        await sdk.pause.resume()
        do {
            _ = try await task.value
            Issue.record("clear後の成功commitまたは失敗呼出はthrowが必要")
        } catch {
            if outcome == "success" { #expect(error is CancellationError) }
        }
        #expect(store.load() == nil)
    }

    @Test("別saveの新tokenを失敗rollbackと古い成功commitが上書きしない", arguments: ["success", "503"])
    func newerSaveWins(outcome: String) async throws {
        let store = OAuthTokenStore(storage: InMemoryTokenStorage())
        store.save(fixtureToken("old"))
        let transaction = OAuthTransactionalStorage(store: store)
        let sdk = PausedOAuthAuthorizer(storage: transaction, outcome: outcome)
        let authorizer = PreservingOAuthAuthorizer(underlying: sdk, storage: transaction)
        let task = Task { try await execute(authorizer) }
        await sdk.pause.waitUntilEntered()
        store.save(fixtureToken("external"))
        await sdk.pause.resume()
        do {
            _ = try await task.value
            Issue.record("世代の違う保存を上書きする呼出はthrowが必要")
        } catch {
            if outcome == "success" { #expect(error is CancellationError) }
        }
        #expect(store.load()?.value == "external")
    }

    @Test("同URLの複数authorizerはrotationを直列化して最新tokenを引き継ぐ")
    func sharedStoreSerializesRotation() async throws {
        let store = OAuthTokenStore(storage: InMemoryTokenStorage())
        store.save(fixtureToken("old"))
        let firstStorage = OAuthTransactionalStorage(store: store)
        let secondStorage = OAuthTransactionalStorage(store: store)
        let firstSDK = PausedOAuthAuthorizer(storage: firstStorage, outcome: "success", next: "first")
        let secondSDK = PausedOAuthAuthorizer(storage: secondStorage, outcome: "success", next: "second")
        let first = PreservingOAuthAuthorizer(underlying: firstSDK, storage: firstStorage)
        let second = PreservingOAuthAuthorizer(underlying: secondSDK, storage: secondStorage)
        let firstTask = Task { try await execute(first) }
        await firstSDK.pause.waitUntilEntered()
        let secondTask = Task { try await execute(second) }
        await firstSDK.pause.resume()
        #expect(try await firstTask.value)
        await secondSDK.pause.waitUntilEntered()
        #expect(secondSDK.observedRefresh == "refresh-first")
        await secondSDK.pause.resume()
        #expect(try await secondTask.value)
        #expect(store.load()?.refreshToken == "refresh-second")
    }

    @MainActor
    @Test("登録簿removeは同URLの共有token storeをclearする")
    func registryRemoveUsesSharedStore() {
        // テスト固有URL/Defaultsのみ。実接続/実資格情報を一切触らない。
        let url = URL(string: "https://remove-\(UUID()).example/mcp")!
        let suite = "oauth-remove-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let registry = ServerRegistryStore(defaults: defaults)
        let entry = registry.add(name: "fixture", url: url)
        let store = OAuthTokenStore.shared(serverURL: url)
        defer { store.clear() }
        store.save(fixtureToken("synthetic"))
        #expect(OAuthTokenStore.shared(serverURL: url) === store)
        registry.remove(id: entry.id)
        #expect(store.load() == nil)
    }
}

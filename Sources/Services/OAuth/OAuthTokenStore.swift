import Foundation
import MCP

// Keychain自体のcacheはinstance単位。共有storeを接続と明示削除で共用しなければ、
// 別instanceのclearを進行中refreshが見逃してtokenを復活させてしまう。
final class OAuthTokenStore: TokenStorage, @unchecked Sendable {
    private static let registryLock = NSLock()
    private static var stores: [String: OAuthTokenStore] = [:]

    static func shared(serverURL: URL) -> OAuthTokenStore {
        registryLock.withLock {
            // Keychain accountと同じabsoluteStringをキーにし、URL同値化で別accountを混ぜない。
            let account = serverURL.absoluteString
            if let store = stores[account] { return store }
            let store = OAuthTokenStore(storage: KeychainTokenStorage(serverURL: serverURL))
            stores[account] = store
            return store
        }
    }

    private let storage: any TokenStorage
    private let lock = NSLock()
    private var generation: UInt64 = 0
    let mutationGate = OAuthMutationGate()

    // fixtureでは同じ境界へfile storageを渡す。Keychain namespace/formatは変えない。
    init(storage: any TokenStorage) { self.storage = storage }
    func load() -> OAuthAccessToken? { lock.withLock { storage.load() } }
    func save(_ token: OAuthAccessToken) {
        lock.withLock { storage.save(token); generation &+= 1 }
    }
    func clear() {
        lock.withLock { storage.clear(); generation &+= 1 }
    }

    func snapshot() -> (token: OAuthAccessToken?, generation: UInt64) {
        lock.withLock { (storage.load(), generation) }
    }

    func commit(token: OAuthAccessToken?, generation expected: UInt64, changed: Bool) throws {
        try lock.withLock {
            // explicit clearだけでなく別保存も拒否条件。古いsnapshotでrotationを巻き戻さない。
            guard generation == expected else { throw CancellationError() }
            guard changed else { return }
            if let token { storage.save(token) } else { storage.clear() }
            generation &+= 1
        }
    }
}

// actorのasync関数はawait中に再入可能なので、actorであるだけではsingle-flightにならない。
// URLごとのgateをnetwork呼出全体に保持し、SDK同士のrefresh rotationを直列化する。
final class OAuthMutationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        await withCheckedContinuation { continuation in
            let acquired = lock.withLock {
                if held { waiters.append(continuation); return false }
                held = true
                return true
            }
            if acquired { continuation.resume() }
        }
    }
    func release() {
        let next: CheckedContinuation<Void, Never>? = lock.withLock {
            if !waiters.isEmpty { return waiters.removeFirst() }
            held = false
            return nil
        }
        next?.resume()
    }
}

// SDKのclearは呼出中だけshadowへ適用する。失敗後の旧token再saveではないので、
// rollbackが明示削除や別refreshの新tokenを復活/上書きすることはない。
final class OAuthTransactionalStorage: TokenStorage, @unchecked Sendable {
    private struct State {
        var token: OAuthAccessToken?
        let generation: UInt64
        var changed = false
    }
    let store: OAuthTokenStore
    private let lock = NSLock()
    private var state: State?

    init(store: OAuthTokenStore) { self.store = store }
    func begin() {
        let snapshot = store.snapshot()
        lock.withLock { state = State(token: snapshot.token, generation: snapshot.generation) }
    }
    func finish(commit: Bool) throws {
        let finished = lock.withLock { let current = state; state = nil; return current }
        if commit, let finished {
            try store.commit(token: finished.token, generation: finished.generation, changed: finished.changed)
        }
    }
    func load() -> OAuthAccessToken? {
        lock.withLock {
            if let state { return state.token }
            return store.load()
        }
    }
    func save(_ token: OAuthAccessToken) {
        lock.withLock {
            if state != nil { state?.token = token; state?.changed = true } else { store.save(token) }
        }
    }
    func clear() {
        lock.withLock {
            if state != nil { state?.token = nil; state?.changed = true } else { store.clear() }
        }
    }
}

// R4 許可決定ストア(ToolPermissionStore)の永続化を検証する。
// 実 UserDefaults を汚さないよう、テスト専用 suite(UserDefaults(suiteName:))を使い、各テストで消す。
import Foundation
import Testing
@testable import Kernel
@testable import Services

@Suite struct ToolPermissionStoreTests {
    private func freshDefaults() -> UserDefaults {
        // ユニークな suite でテスト間の相互汚染を防ぐ(実 standard を触らない)。
        let suite = "test.toolPermission.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private let server = URL(string: "https://caldav.example/mcp")!

    @Test("未保存のツールは既定 ask(性悪説)")
    func defaultsToAsk() {
        let store = ToolPermissionStore(defaults: freshDefaults())
        #expect(store.decision(serverURL: server, toolName: "delete-todo") == .ask)
    }

    @Test("allow / deny を保存して読み戻せる")
    func persistsAllowAndDeny() {
        let store = ToolPermissionStore(defaults: freshDefaults())
        store.setDecision(.allow, serverURL: server, toolName: "list-todos")
        store.setDecision(.deny, serverURL: server, toolName: "delete-todo")
        #expect(store.decision(serverURL: server, toolName: "list-todos") == .allow)
        #expect(store.decision(serverURL: server, toolName: "delete-todo") == .deny)
    }

    @Test("明示 ask は保存され storedDecision が nil でなく .ask を返す(設計の穴 end-to-end 回帰)")
    func explicitAskIsPersisted() {
        // 旧実装は setDecision(.ask) がキーを消し storedDecision→nil→gate が readOnly closed を
        // defaultDecision で .allow へ昇格させ、明示 .ask が無視されていた(2026-07-24 修正の穴)。
        // ここでは「明示 ask は未保存(nil)と区別して保存される」ことを固定する。
        let store = ToolPermissionStore(defaults: freshDefaults())
        store.setDecision(.allow, serverURL: server, toolName: "list-todos")
        store.setDecision(.ask, serverURL: server, toolName: "list-todos")
        #expect(store.storedDecision(serverURL: server, toolName: "list-todos") == .ask)
        #expect(store.decision(serverURL: server, toolName: "list-todos") == .ask)
    }

    @Test("clearDecision で明示決定が消え、storedDecision が nil(未保存)へ戻る")
    func clearRestoresUnset() {
        let store = ToolPermissionStore(defaults: freshDefaults())
        store.setDecision(.ask, serverURL: server, toolName: "list-todos")
        #expect(store.storedDecision(serverURL: server, toolName: "list-todos") == .ask)
        store.clearDecision(serverURL: server, toolName: "list-todos")
        #expect(store.storedDecision(serverURL: server, toolName: "list-todos") == nil)
        #expect(store.decision(serverURL: server, toolName: "list-todos") == .ask)  // 既定へ戻る
    }

    @Test("未保存ツールの storedDecision は nil(明示 ask と区別する)")
    func unsetReturnsNil() {
        let store = ToolPermissionStore(defaults: freshDefaults())
        #expect(store.storedDecision(serverURL: server, toolName: "delete-todo") == nil)
    }

    @Test("同名ツールでも serverURL が違えば決定は混ざらない")
    func serverScoped() {
        let store = ToolPermissionStore(defaults: freshDefaults())
        let other = URL(string: "https://other.example/mcp")!
        store.setDecision(.deny, serverURL: server, toolName: "sync")
        #expect(store.decision(serverURL: server, toolName: "sync") == .deny)
        #expect(store.decision(serverURL: other, toolName: "sync") == .ask)
    }

    @Test("AllowAllToolPermissionStore は常に allow(注入省略時の後方互換)")
    func allowAllStore() {
        let store = AllowAllToolPermissionStore()
        #expect(store.decision(serverURL: server, toolName: "anything") == .allow)
    }
}

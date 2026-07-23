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

    @Test("ask を保存するとキーが消え、既定へ戻る(肥大化を避ける)")
    func askClearsKey() {
        let store = ToolPermissionStore(defaults: freshDefaults())
        store.setDecision(.allow, serverURL: server, toolName: "list-todos")
        store.setDecision(.ask, serverURL: server, toolName: "list-todos")
        #expect(store.decision(serverURL: server, toolName: "list-todos") == .ask)
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

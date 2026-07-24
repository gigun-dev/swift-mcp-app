// R4 許可ゲートを ToolCallRunner のレベルで検証する(UI を介さず confirm closure を直接注入)。
// What(テスト = 仕様): decision × annotations で「即実行 / 確認して実行 / 確認して中止 / deny 即中止」の
// どれになるか、確認結果 allowAlways がストアへ .allow を保存するか、readOnly 申告で確認を飛ばすか。
//
// StubToolExecutor(呼ばれた name/arguments を記録)を再利用し、「実際に callTool されたか」で判定する。
import Foundation
import Testing
@testable import Kernel
@testable import Services

/// 決め打ちの**保存済み**決定(nil = 未保存)を返し、setDecision の呼び出しを記録するストア。
/// 同期メソッドなので actor にできない(Runner は非 async で呼ぶ)。NSLock で記録を直列化する。
///
/// 2026-07-24 refactor: gate が storedDecision(optional)を引く形になったので、この stub も
/// 「未保存(nil)」と「明示保存(.allow/.ask/.deny)」を区別して返す。nil のときは gate 側で
/// defaultDecision(annotations 由来)が当たる — 「未保存 readOnly closed は自動許可」を再現できる。
private final class RecordingPermissionStore: ToolPermissionResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let stored: ToolPermissionDecision?
    private var _recorded: [(decision: ToolPermissionDecision, toolName: String)] = []

    /// - Parameter stored: ユーザーが明示保存した決定。nil = 未保存(gate が既定を当てる)。
    init(stored: ToolPermissionDecision?) { self.stored = stored }

    var recorded: [(decision: ToolPermissionDecision, toolName: String)] {
        lock.lock(); defer { lock.unlock() }
        return _recorded
    }

    func storedDecision(serverURL: URL?, toolName: String) -> ToolPermissionDecision? { stored }

    func setDecision(_ decision: ToolPermissionDecision, serverURL: URL?, toolName: String) {
        lock.lock(); defer { lock.unlock() }
        _recorded.append((decision, toolName))
    }

    // このゲート検証では clearDecision は呼ばれない(設定画面 S2 の導線)。プロトコル充足のため no-op。
    func clearDecision(serverURL: URL?, toolName: String) {}
}

@Suite struct ToolCallRunnerGateTests {
    private func call(_ id: String, _ name: String, _ args: String = "{}") -> ToolCall {
        ToolCall(id: id, function: .init(name: name, arguments: args))
    }

    private func makeRunner(
        executor: StubToolExecutor,
        annotations: [String: ToolAnnotations] = [:],
        store: any ToolPermissionResolving
    ) -> ToolCallRunner {
        ToolCallRunner(
            executor: executor,
            resourceURIs: [:],
            serverNames: ["tool": "caldav"],
            originalToolNames: ["tool": "tool"],
            serverIDs: [:],
            serverURLs: [:],
            traceSink: nil,
            annotationsByTool: annotations,
            permissionStore: store
        )
    }

    @Test("deny 決定は callTool せず、拒否メッセージを wire に返す")
    func denyBlocksExecution() async {
        let executor = StubToolExecutor(results: ["tool": .string("ok")])
        let runner = makeRunner(executor: executor, store: RecordingPermissionStore(stored: .deny))
        let batch = await runner.run([call("c1", "tool")], turnId: "t")

        #expect(await executor.calls.isEmpty)
        #expect(batch.steps[0].state == .failed)
        #expect(batch.wireMessages[0].content?.contains("拒否") == true)
        #expect(batch.cards.isEmpty)
    }

    @Test("allow 決定は確認なしで実行する")
    func allowProceedsWithoutConfirm() async {
        let executor = StubToolExecutor(results: ["tool": .string("ok")])
        let runner = makeRunner(executor: executor, store: RecordingPermissionStore(stored: .allow))
        var confirmCalled = false
        let batch = await runner.run([call("c1", "tool")], turnId: "t") { _ in
            confirmCalled = true
            return .deny
        }
        #expect(confirmCalled == false)
        #expect(await executor.calls.count == 1)
        #expect(batch.steps[0].state == .done)
    }

    @Test("ask + 未申告は確認を出し、allowOnce なら実行(保存はしない)")
    func askConfirmAllowOnce() async {
        let executor = StubToolExecutor(results: ["tool": .string("ok")])
        let store = RecordingPermissionStore(stored: nil)
        let runner = makeRunner(executor: executor, store: store)
        let batch = await runner.run([call("c1", "tool")], turnId: "t") { _ in .allowOnce }
        #expect(await executor.calls.count == 1)
        #expect(batch.steps[0].state == .done)
        #expect(store.recorded.isEmpty)  // allowOnce は保存しない
    }

    @Test("ask + 確認で allowAlways ならストアへ .allow を保存し実行する")
    func askConfirmAllowAlwaysPersists() async {
        let executor = StubToolExecutor(results: ["tool": .string("ok")])
        let store = RecordingPermissionStore(stored: nil)
        let runner = makeRunner(executor: executor, store: store)
        _ = await runner.run([call("c1", "tool")], turnId: "t") { _ in .allowAlways }
        #expect(await executor.calls.count == 1)
        #expect(store.recorded.count == 1)
        #expect(store.recorded.first?.decision == .allow)
        #expect(store.recorded.first?.toolName == "tool")
    }

    @Test("ask + 確認で deny なら実行せず拒否メッセージ(保存しない)")
    func askConfirmDenyBlocks() async {
        let executor = StubToolExecutor(results: ["tool": .string("ok")])
        let store = RecordingPermissionStore(stored: nil)
        let runner = makeRunner(executor: executor, store: store)
        let batch = await runner.run([call("c1", "tool")], turnId: "t") { _ in .deny }
        #expect(await executor.calls.isEmpty)
        #expect(batch.steps[0].state == .failed)
        #expect(store.recorded.isEmpty)
    }

    @Test("未保存 + readOnly かつ openWorldHint==false は確認を飛ばして実行(defaultDecision で自動許可)")
    func askReadOnlySkipsConfirm() async {
        let executor = StubToolExecutor(results: ["tool": .string("ok")])
        // stored: nil = 未保存。gate は defaultDecision(annotations) を当て、readOnly closed なので .allow。
        let store = RecordingPermissionStore(stored: nil)
        let runner = makeRunner(
            executor: executor,
            // 緩和の唯一の形: readOnly かつ open-world でないことを明示申告(caldav の全ツールがこれ)。
            // openWorldHint 未申告(nil)だと spec 既定 open-world=true とみなされ confirm 側へ倒れる(S1 厳密化)。
            annotations: ["tool": ToolAnnotations(readOnlyHint: true, openWorldHint: false)],
            store: store
        )
        var confirmCalled = false
        let batch = await runner.run([call("c1", "tool")], turnId: "t") { _ in
            confirmCalled = true
            return .deny
        }
        #expect(confirmCalled == false)
        #expect(await executor.calls.count == 1)
        #expect(batch.steps[0].state == .done)
    }

    @Test("明示 .ask を保存した readOnly closed は確認する(hint 緩和より明示決定が優先・設計の穴回帰)")
    func explicitAskOnReadOnlyStillConfirms() async {
        let executor = StubToolExecutor(results: ["tool": .string("ok")])
        // ユーザーが設定画面で明示的に「承認が必要(.ask)」を保存した readOnly closed ツール。
        // 以前は evaluate が readOnly を緩和して確認をスキップし、この明示選択を握りつぶしていた(修正済み)。
        let store = RecordingPermissionStore(stored: .ask)
        let runner = makeRunner(
            executor: executor,
            annotations: ["tool": ToolAnnotations(readOnlyHint: true, openWorldHint: false)],
            store: store
        )
        var confirmCalled = false
        let batch = await runner.run([call("c1", "tool")], turnId: "t") { _ in
            confirmCalled = true
            return .allowOnce
        }
        #expect(confirmCalled == true)  // 明示 .ask なので必ず確認が出る
        #expect(await executor.calls.count == 1)  // allowOnce 応答で実行はされる
        #expect(batch.steps[0].state == .done)
    }

    @Test("実 ToolPermissionStore に .ask を保存した readOnly closed は confirm される(store 経由 end-to-end 回帰)")
    func explicitAskViaRealStoreConfirms() async {
        // stub でなく実ストア経由。setDecision(.ask) がキーを消していた旧実装だと storedDecision→nil→
        // defaultDecision で .allow へ昇格し確認がスキップされた(穴の end-to-end 再発)。3 値保存で塞ぐ。
        let suite = "test.gate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let serverURL = URL(string: "https://caldav.example/mcp")!
        let store = ToolPermissionStore(defaults: defaults)
        store.setDecision(.ask, serverURL: serverURL, toolName: "tool")

        let executor = StubToolExecutor(results: ["tool": .string("ok")])
        let runner = ToolCallRunner(
            executor: executor,
            resourceURIs: [:],
            serverNames: ["tool": "caldav"],
            originalToolNames: ["tool": "tool"],
            serverIDs: [:],
            serverURLs: ["tool": serverURL],  // storedDecision のキー解決に必要(serverURL × originalName)
            traceSink: nil,
            annotationsByTool: ["tool": ToolAnnotations(readOnlyHint: true, openWorldHint: false)],
            permissionStore: store
        )
        var confirmCalled = false
        _ = await runner.run([call("c1", "tool")], turnId: "t") { _ in
            confirmCalled = true
            return .allowOnce
        }
        #expect(confirmCalled == true)  // 明示 .ask が実ストアから読まれ、確認が出る
    }
}

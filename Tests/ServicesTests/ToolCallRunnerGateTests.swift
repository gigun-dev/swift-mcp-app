// R4 許可ゲートを ToolCallRunner のレベルで検証する(UI を介さず confirm closure を直接注入)。
// What(テスト = 仕様): decision × annotations で「即実行 / 確認して実行 / 確認して中止 / deny 即中止」の
// どれになるか、確認結果 allowAlways がストアへ .allow を保存するか、readOnly 申告で確認を飛ばすか。
//
// StubToolExecutor(呼ばれた name/arguments を記録)を再利用し、「実際に callTool されたか」で判定する。
import Foundation
import Testing
@testable import Kernel
@testable import Services

/// 決め打ちの決定を返し、setDecision の呼び出しを記録するストア。
/// 同期メソッドなので actor にできない(Runner は非 async で呼ぶ)。NSLock で記録を直列化する。
private final class RecordingPermissionStore: ToolPermissionResolving, @unchecked Sendable {
    private let lock = NSLock()
    private let fixed: ToolPermissionDecision
    private var _recorded: [(decision: ToolPermissionDecision, toolName: String)] = []

    init(fixed: ToolPermissionDecision) { self.fixed = fixed }

    var recorded: [(decision: ToolPermissionDecision, toolName: String)] {
        lock.lock(); defer { lock.unlock() }
        return _recorded
    }

    func decision(serverURL: URL?, toolName: String) -> ToolPermissionDecision { fixed }

    func setDecision(_ decision: ToolPermissionDecision, serverURL: URL?, toolName: String) {
        lock.lock(); defer { lock.unlock() }
        _recorded.append((decision, toolName))
    }
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
        let runner = makeRunner(executor: executor, store: RecordingPermissionStore(fixed: .deny))
        let batch = await runner.run([call("c1", "tool")], turnId: "t")

        #expect(await executor.calls.isEmpty)
        #expect(batch.steps[0].state == .failed)
        #expect(batch.wireMessages[0].content?.contains("拒否") == true)
        #expect(batch.cards.isEmpty)
    }

    @Test("allow 決定は確認なしで実行する")
    func allowProceedsWithoutConfirm() async {
        let executor = StubToolExecutor(results: ["tool": .string("ok")])
        let runner = makeRunner(executor: executor, store: RecordingPermissionStore(fixed: .allow))
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
        let store = RecordingPermissionStore(fixed: .ask)
        let runner = makeRunner(executor: executor, store: store)
        let batch = await runner.run([call("c1", "tool")], turnId: "t") { _ in .allowOnce }
        #expect(await executor.calls.count == 1)
        #expect(batch.steps[0].state == .done)
        #expect(store.recorded.isEmpty)  // allowOnce は保存しない
    }

    @Test("ask + 確認で allowAlways ならストアへ .allow を保存し実行する")
    func askConfirmAllowAlwaysPersists() async {
        let executor = StubToolExecutor(results: ["tool": .string("ok")])
        let store = RecordingPermissionStore(fixed: .ask)
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
        let store = RecordingPermissionStore(fixed: .ask)
        let runner = makeRunner(executor: executor, store: store)
        let batch = await runner.run([call("c1", "tool")], turnId: "t") { _ in .deny }
        #expect(await executor.calls.isEmpty)
        #expect(batch.steps[0].state == .failed)
        #expect(store.recorded.isEmpty)
    }

    @Test("ask + readOnly かつ openWorldHint==false 申告のツールは確認を飛ばして実行する(唯一の緩和)")
    func askReadOnlySkipsConfirm() async {
        let executor = StubToolExecutor(results: ["tool": .string("ok")])
        let store = RecordingPermissionStore(fixed: .ask)
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
}

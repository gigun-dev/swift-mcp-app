// fullscreen の実 presentation 完了と request-display-mode 応答を結ぶ gate の単体テスト。
// UIKit/SwiftUI を使わず、成功・timeout・画面破棄の三出口を決定的に固定する。
import Testing

@testable import Services

@Suite @MainActor struct FullscreenPresentationGateTests {
    @Test("finish は実reparent成立として true を返す")
    func finishReturnsConfirmed() async {
        let gate = FullscreenPresentationGate(timeout: .seconds(1))
        let waiter = Task { await gate.wait() }
        while !gate.isWaiting { await Task.yield() }

        gate.finish()

        #expect(await waiter.value)
        #expect(!gate.isWaiting)
    }

    @Test("timeout はfullscreen未成立として false を返す")
    func timeoutReturnsUnconfirmed() async {
        let gate = FullscreenPresentationGate(timeout: .milliseconds(5))

        let confirmed = await gate.wait()

        #expect(!confirmed)
        #expect(!gate.isWaiting)
    }

    @Test("cancel は画面破棄として false を返す")
    func cancelReturnsUnconfirmed() async {
        let gate = FullscreenPresentationGate(timeout: .seconds(1))
        let waiter = Task { await gate.wait() }
        while !gate.isWaiting { await Task.yield() }

        gate.cancel()

        #expect(await !waiter.value)
        #expect(!gate.isWaiting)
    }
}

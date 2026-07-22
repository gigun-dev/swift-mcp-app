// InlineCardHost と fullscreen presentation gate の連携。UI非依存の待機状態機械は Services の
// FullscreenPresentationGate に置き、このファイルは SwiftUI reparent の成立/rollback だけを担う。
import Kernel
import Services

extension InlineCardHost {
    /// カード発要求を調停役へ渡し、実 reparent まで待ってから結果を返す。
    func resolveDisplayMode(_ requested: UIDisplayMode) async -> DisplayModeResolution {
        guard requested == .fullscreen, let fullscreenCoordinator else {
            return DisplayModeResolution(mode: .inline)
        }
        let requiresReparent = displayMode != .fullscreen
        let dimensions = estimatedFullscreenDimensions()
        let resolution = fullscreenCoordinator.requestFullscreen(self, estimatedDimensions: dimensions)
        guard resolution.mode == .fullscreen else { return resolution }

        pendingDisplayModeNotification = (.fullscreen, dimensions)
        guard requiresReparent else { return resolution } // 冪等要求は既に実表示済みなので待たない。

        // 成功応答を先に返すと、カードの応答後 focus が reparent 途中で走り keyboard が消える。
        // timeout/cancel は「fullscreen が成立した」と偽らず inline へ rollback して安全側を返す。
        let didReparent = await fullscreenPresentationGate.wait()
        guard didReparent else {
            fullscreenCoordinator.dismiss()
            return DisplayModeResolution(mode: .inline)
        }
        return resolution
    }

    /// AppCardView.onAdopted から呼ばれ、実際の載せ替え後に保留中 context をカードへ送る。
    func notifyReparented() {
        guard let pending = pendingDisplayModeNotification else { return }
        pendingDisplayModeNotification = nil
        let session = self.session

        // waiter は reparent という物理的事実をここで同期確定する。これ以降に返る result 後の focus は
        // 安定した fullscreen WKWebView 上で走る。context 通知は同じ adopt フックから続けて配送する。
        if pending.mode == .fullscreen { fullscreenPresentationGate.finish() }
        Task {
            await session?.notifyDisplayModeChanged(to: pending.mode, containerDimensions: pending.dims)
        }
    }
}

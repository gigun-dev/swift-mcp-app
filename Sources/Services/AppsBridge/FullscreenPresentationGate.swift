// ui/request-display-mode の成功応答を、Features が実 presentation 完了を確認するまで待たせる状態機械。
// UIKit/SwiftUI には依存せず、AppsBridge の非同期応答境界として swift test 可能な Services に置く。
//
// 【原因(2026-07-23 Simulator D)】旧実装は displayMode の状態更新直後に fullscreen を返したため、
// カードが Promise 完了後に focus() すると fullScreenCover/reparent と競合し、WKContentView が
// removeFromSuperview で resign → keyboard が show 直後に hide した。DOM を推測して再focusするのでなく、
// 「成功応答 = 要求モードのコンテナが実在する」という一般的な境界をホストが保証する。
import Foundation

@MainActor
public final class FullscreenPresentationGate {
    private let timeout: Duration
    private var pending: (token: UUID, continuation: CheckedContinuation<Bool, Never>)?

    public var isWaiting: Bool { pending != nil }

    /// 本番は2秒。テストでは短い Duration を注入し、timeoutを待ち時間なしで固定できる。
    public init(timeout: Duration = .seconds(2)) {
        self.timeout = timeout
    }

    /// `true` は finish()=実 reparent 確認、`false` は timeout/cancel=未成立。
    public func wait() async -> Bool {
        let token = UUID()
        return await withCheckedContinuation { continuation in
            // 冪等な同時要求で古い waiter を残さない。置換された要求は未成立(false)で解放する。
            completeCurrent(with: false)
            pending = (token, continuation)
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: timeout)
                complete(token: token, result: false)
            }
        }
    }

    /// reparent 完了時の成功出口。
    public func finish() {
        completeCurrent(with: true)
    }

    /// 画面破棄時の未成立出口。
    public func cancel() {
        completeCurrent(with: false)
    }

    private func completeCurrent(with result: Bool) {
        guard let pending else { return }
        complete(token: pending.token, result: result)
    }

    /// reparent/timeout/cancel が競合しても現在tokenと一致する一度だけresumeする。
    private func complete(token: UUID, result: Bool) {
        guard let pending, pending.token == token else { return }
        self.pending = nil
        pending.continuation.resume(returning: result)
    }
}

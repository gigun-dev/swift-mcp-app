// R4 許可ゲート(HITL)の確認キュー。Runner の confirm closure と確認 UI(SwiftUI)の間を仲介する。
//
// なぜ ChatViewModel から切り出すか: ChatViewModel は会話状態機械が本務で、確認待ちの continuation 管理
// (並行 tool call で複数同時に積まれうる)を混ぜると責務が膨らむ。ここへ隔離し、ChatViewModel は
// `toolConfirmations.enqueue(_:)` を Runner へ渡し、View は `toolConfirmations.pending` を観測して
// `respond(id:response:)` で応答する、という薄い contract だけに絞る。
//
// @MainActor @Observable: pending は SwiftUI(確認ダイアログ)が観測する。continuation dict は
// MainActor 隔離なので並行 tool call からの enqueue でも直列化され、競合しない。
import Foundation
import Observation
import Kernel

@MainActor
@Observable
public final class ToolConfirmationQueue {
    /// 確認待ちの要求(UI が観測)。先頭からダイアログにする。空 = 確認待ちなし。
    public private(set) var pending: [ToolCallConfirmationRequest] = []

    /// 各要求の continuation。respond で応答が来たら resume して Runner の await を解く。
    private var continuations: [UUID: CheckedContinuation<ToolCallConfirmationResponse, Never>] = [:]

    public init() {}

    /// Runner の confirm closure から呼ばれ、要求を積んで応答を待つ。respond まで suspend する。
    func enqueue(_ request: ToolCallConfirmationRequest) async -> ToolCallConfirmationResponse {
        await withCheckedContinuation { continuation in
            continuations[request.id] = continuation
            pending.append(request)
        }
    }

    /// View(確認ダイアログ)から応答を返す。該当要求を行列から外し、Runner の await を解く。
    /// 未知 id(二重応答・キャンセル後)は黙って無視する(冪等)。
    public func respond(id: UUID, response: ToolCallConfirmationResponse) {
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        pending.removeAll { $0.id == id }
        continuation.resume(returning: response)
    }

    /// 待ち行列の全要求を deny で解く(send のキャンセル時の後始末)。
    /// これをしないと Runner の TaskGroup 子が await のまま残り、cancel が完了しない。
    func failAll() {
        let snapshot = continuations
        continuations.removeAll()
        pending.removeAll()
        for continuation in snapshot.values {
            continuation.resume(returning: .deny)
        }
    }
}

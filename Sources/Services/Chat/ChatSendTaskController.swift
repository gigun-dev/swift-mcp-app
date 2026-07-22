/// Viewから開始したsend/retryのTaskを1本だけ保持し、画面破棄や新規チャット時にキャンセルする。
@MainActor
final class ChatSendTaskController {
    private var activeTask: Task<Void, Never>?

    func submit(_ operation: @escaping @MainActor () async -> Void) {
        activeTask?.cancel()
        activeTask = Task { await operation() }
    }

    func cancel() {
        activeTask?.cancel()
    }
}

import SwiftUI
import UIKit
import Kernel

extension HistoryDetailView {
    func historyAssistantActions(_ turn: ChatTurn) -> some View {
        HStack(spacing: 2) {
            historyActionButton("doc.on.doc", label: "回答をコピー") { copy(turn.text) }
            historyActionButton(
                turn.feedback == .positive ? "hand.thumbsup.fill" : "hand.thumbsup",
                label: "良い回答",
                enabled: false
            ) {}
            historyActionButton(
                turn.feedback == .negative ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                label: "良くない回答",
                enabled: false
            ) {}
            historyActionButton("arrow.clockwise", label: "応答を再生成", enabled: false) {}
        }
        .foregroundStyle(.secondary)
    }

    private func historyActionButton(
        _ systemName: String,
        label: String,
        enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption)
                .frame(width: 30, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    func copy(_ text: String) {
        UIPasteboard.general.string = text
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        ChatTopToast.show("コピーしました")
        UIAccessibility.post(notification: .announcement, argument: "コピーしました")
    }
}

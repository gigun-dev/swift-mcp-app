import SwiftUI

extension Notification.Name {
    static let chatTopToastRequested = Notification.Name("dev.gigun.mcphost.chatTopToastRequested")
}

enum ChatTopToast {
    static func show(_ message: String, systemImage: String = "checkmark.circle.fill") {
        NotificationCenter.default.post(
            name: .chatTopToastRequested,
            object: nil,
            userInfo: ["message": message, "systemImage": systemImage]
        )
    }
}

private struct ChatTopToastModifier: ViewModifier {
    private struct Toast: Equatable {
        let id = UUID()
        let message: String
        let systemImage: String
    }

    @State private var toast: Toast?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .top) {
                if let toast {
                    HStack(spacing: 9) {
                        Image(systemName: toast.systemImage)
                            .foregroundStyle(.green)
                        Text(toast.message)
                            .font(.callout.weight(.semibold))
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 48)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color(uiColor: .separator), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.16), radius: 12, y: 5)
                    .padding(.top, topSafeAreaInset + 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .accessibilityAddTraits(.isStaticText)
                    .zIndex(100)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .chatTopToastRequested)) { notification in
                guard let message = notification.userInfo?["message"] as? String else { return }
                let systemImage = notification.userInfo?["systemImage"] as? String ?? "checkmark.circle.fill"
                present(Toast(message: message, systemImage: systemImage))
            }
    }

    private var topSafeAreaInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .safeAreaInsets.top ?? 0
    }

    private func present(_ newToast: Toast) {
        if reduceMotion {
            toast = newToast
        } else {
            withAnimation(.easeOut(duration: 0.2)) { toast = newToast }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard toast?.id == newToast.id else { return }
            if reduceMotion {
                toast = nil
            } else {
                withAnimation(.easeIn(duration: 0.16)) { toast = nil }
            }
        }
    }
}

extension View {
    func chatTopToastHost() -> some View {
        modifier(ChatTopToastModifier())
    }
}

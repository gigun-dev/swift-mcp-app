import SwiftUI
import Services

/// 入力下書き・送信可否・利用量表示をまとめるチャット composer。
struct ChatComposerView: View {
    let chatVM: ChatViewModel
    @Binding var draft: String
    @FocusState.Binding var inputFocused: Bool
    let haptics: ChatHapticsController
    let modelName: String
    let reasoningEffort: String
    let onShowModelSelection: () -> Void
    let onWillSend: () -> Void

    // MARK: - 入力バー(モックの .composer)

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // エラー(赤字・タスク指示)。次の送信で ChatViewModel 側が消す。
            if let error = chatVM.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }

            VStack(alignment: .leading, spacing: 8) {
                TextField("メッセージを入力…", text: $draft, axis: .vertical)
                    .lineLimit(1 ... 4)
                    .focused($inputFocused)  // キーボード dismiss を制御するため focus を束ねる。
                    // UITest から掴むための識別子(既存の "home.root" と同じ命名規則)。
                    // 2026-08-01: 入力欄の長押し(ペースト/選択)でキーボードが落ちる不具合の
                    // 回帰テスト(SmokeUITests.testLongPressInComposerKeepsKeyboard)で使う。
                    .accessibilityIdentifier("chat.composer.input")
                    .disabled(chatVM.isRunning)

                HStack(spacing: 8) {
                    Button(action: onShowModelSelection) {
                        Text(selectionLabel)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 12)
                            .frame(height: 34)
                            .background(Capsule().fill(Color(.tertiarySystemFill)))
                    }
                    .buttonStyle(.plain)
                    .disabled(chatVM.isRunning)

                    Spacer()
                    Button(action: sendDraft) {
                        Image(systemName: "arrow.up")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(canSend ? Color.accentColor : Color.gray))
                    }
                    .disabled(!canSend)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(.secondarySystemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color(.separator), lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// 送信可能条件: 実行中でなく、下書きが空白でない。
    private var canSend: Bool {
        !chatVM.isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var selectionLabel: String {
        let effort = LLMReasoningEffort.label(for: reasoningEffort)
        return reasoningEffort.isEmpty ? modelName : "\(modelName)  \(effort)"
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onWillSend()
        draft = ""
        inputFocused = false  // 送信したらキーボードを閉じる(応答を見やすく・出っぱなし対策)。
        haptics.sent()  // 送信確定の軽い合図(タスク指示 2)。
        // ChatViewModel.submit は throw しない(内部の send が errorMessage に載せる)。VM 自身が
        // Task を保持する形にしたので、View 側は Task { } で包まない(監査 2026-07-18 MEDIUM)。
        chatVM.submit(text)
    }
}

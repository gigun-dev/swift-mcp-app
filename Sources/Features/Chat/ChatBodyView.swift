// チャット本体(T4-B・モック chat-v1.html「1. チャット本体」を SwiftUI 化)。
// ChatViewModel.turns を描画し、下部に入力欄 + コスト表示を出す。
//
// モック対応(chat-v1.html:196-243):
//  - .messages(縦スクロール・吹き出し列)→ ScrollView + LazyVStack。
//  - .bubble.user / .bubble.assistant → 右寄せ青 / 左寄せ白の吹き出し。
//  - .tool-step(🔧 <tool> …running)→ ツールステップ行(running/done/failed を状態で出し分け)。
//  - .composer(.cost-hint + textarea + send)→ 入力欄の上に「このターン ≈ N tok」+ TextField + 送信。
//  - errorMessage → 赤字表示(モックには無いが設計・タスク指示で要求)。
//
// **カードは出さない**(T5)。ツール結果はモデルの最終テキスト(assistant 吹き出し)に現れる。
// ChatTurn.cards は今回は空のまま(描画もしない)。
import SwiftUI
import Kernel   // ChatTurn・ToolCallStep・Usage・ChatMessage.Role
import Services // ChatViewModel(@MainActor @Observable)

struct ChatBodyView: View {
    // @Bindable 不要(双方向束縛する公開プロパティが ChatViewModel に無い・turns 等は read-only)。
    // @Observable なので let で保持していても body 内で読んだプロパティの変化は自動追従する。
    let chatVM: ChatViewModel

    // 入力欄のローカル下書き。送信で空にする。View ローカルの @State でよい(VM に持たせる必要なし)。
    @State private var draft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            messages
            Divider()
            composer
        }
    }

    // MARK: - メッセージ列

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(chatVM.turns.enumerated()), id: \.offset) { index, turn in
                        turnView(turn)
                            .id(index)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
            // 末尾ターンの text が伸びる(ストリーミング)たびに最下部へ追従する。
            // turns.count だけでなく末尾 text の長さも監視して、ストリーミング中の追従を効かせる。
            .onChange(of: chatVM.turns.count) { scrollToBottom(proxy) }
            .onChange(of: chatVM.turns.last?.text) { scrollToBottom(proxy) }
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard !chatVM.turns.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(chatVM.turns.count - 1, anchor: .bottom)
        }
    }

    // MARK: - 1ターン

    @ViewBuilder
    private func turnView(_ turn: ChatTurn) -> some View {
        switch turn.role {
        case .user:
            // ユーザー吹き出し: 右寄せ・青。
            HStack {
                Spacer(minLength: 40)
                bubble(turn.text, isUser: true)
            }
        case .assistant:
            // assistant: ツールステップ列(あれば)を先に、続いて本文吹き出し(空なら出さない)。
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(turn.toolSteps.enumerated()), id: \.offset) { _, step in
                    toolStepRow(step)
                }
                if !turn.text.isEmpty {
                    HStack {
                        bubble(turn.text, isUser: false)
                        Spacer(minLength: 40)
                    }
                }
            }
        case .system, .tool:
            // system / tool は wire 専用でありターン表示には現れない(ChatViewModel は
            // turns に user/assistant しか積まない)。将来のために握りつぶさず何も出さない。
            EmptyView()
        }
    }

    private func bubble(_ text: String, isUser: Bool) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(isUser ? Color.white : Color.primary)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(isUser ? Color.accentColor : Color(.secondarySystemBackground))
            )
            .frame(maxWidth: 300, alignment: isUser ? .trailing : .leading)
            .textSelection(.enabled)  // 長い応答をコピーできるように(デバッグ・実用両面で有用)。
    }

    // MARK: - ツールステップ行(モックの .tool-step)

    private func toolStepRow(_ step: ToolCallStep) -> some View {
        HStack(spacing: 6) {
            // 状態アイコン: running=スピナー / done=チェック / failed=× / pending=時計。
            switch step.state {
            case .running:
                ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            case .pending:
                Image(systemName: "clock").foregroundStyle(.secondary)
            }
            // 🔧 <toolName>(モックは code タグでツール名を強調)。等幅 + 薄い accent 背景。
            Text("🔧")
            Text(step.toolName)
                .font(.caption.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.14)))
                .foregroundStyle(Color.accentColor)
            Text(stepStatusLabel(step.state))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.leading, 2)
    }

    private func stepStatusLabel(_ state: ToolCallStep.State) -> String {
        switch state {
        case .pending: return "待機中"
        case .running: return "を呼び出し中…"
        case .done: return "完了"
        case .failed: return "失敗"
        }
    }

    // MARK: - 入力バー(モックの .composer)

    private var composer: some View {
        VStack(alignment: .leading, spacing: 4) {
            // エラー(赤字・タスク指示)。次の送信で ChatViewModel 側が消す。
            if let error = chatVM.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 4)
            }

            // コスト表示(モックの .cost-hint)。T7 前なのでトークン数だけ($ は出さない)。
            costHint

            HStack(alignment: .bottom, spacing: 8) {
                TextField("メッセージを入力…", text: $draft, axis: .vertical)
                    .lineLimit(1...4)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 18).fill(Color(.secondarySystemBackground)))
                    .disabled(chatVM.isRunning)

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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    /// コスト表示行。lastUsage(このターン)と cumulativeUsage(累計)を控えめに出す。
    /// 未計上(まだ1ターンも走っていない)なら何も出さない(嘘の 0 を見せない)。
    @ViewBuilder
    private var costHint: some View {
        if let usage = chatVM.lastUsage {
            let total = usage.totalTokens ?? (usage.promptTokens + usage.completionTokens)
            let cumulative = chatVM.cumulativeUsage
            let cumulativeTotal = cumulative?.totalTokens
                ?? cumulative.map { $0.promptTokens + $0.completionTokens }
            HStack(spacing: 8) {
                Text("このターン ≈ \(total.formatted()) tok")
                if let cumulativeTotal {
                    Text("· 累計 \(cumulativeTotal.formatted()) tok")
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    /// 送信可能条件: 実行中でなく、下書きが空白でない。
    private var canSend: Bool {
        !chatVM.isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        // ChatViewModel.send は throw しない(内部で errorMessage に載せる)。
        Task { await chatVM.send(text) }
    }
}

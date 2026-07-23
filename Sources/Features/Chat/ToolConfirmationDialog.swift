// R4 許可ゲート(HITL)の実行前確認 UI。ChatViewModel.pendingToolConfirmations の先頭を
// confirmationDialog で見せ、ユーザーの選択(1回許可 / 常に許可 / 拒否)を respondToToolConfirmation へ返す。
//
// 【なぜ confirmationDialog か(専用シートでなく)】選択肢は3つの短いアクション + 数行の説明で、
// iOS 標準の action sheet(confirmationDialog)がそのまま合う。破壊的ツールの「拒否」を .destructive で
// 赤く出せるのも標準の作法どおり。専用シートは引数を長く見せたいとき(次 slice の設定画面)に検討する。
//
// 【キュー処理】並行 tool call で複数要求が同時に積まれても、常に先頭1件だけダイアログにする。
// 応答すると先頭が外れ、次があれば SwiftUI が item の変化を検知して自動で次のダイアログを出す
// (presenting: に先頭要求を渡し、item が変わるたび再提示される)。
import SwiftUI
import Kernel
import Services

extension View {
    /// チャット本体へ R4 確認ダイアログを載せる。chatVM の確認キューを観測して先頭を提示する。
    func toolConfirmationDialog(chatVM: ChatViewModel) -> some View {
        modifier(ToolConfirmationDialogModifier(chatVM: chatVM))
    }
}

private struct ToolConfirmationDialogModifier: ViewModifier {
    // @Bindable で @Observable な ChatViewModel を観測し、pendingToolConfirmations の変化で再評価する。
    @Bindable var chatVM: ChatViewModel

    func body(content: Content) -> some View {
        // 先頭の確認要求(なければ nil)。isPresented はこの有無へ連動させる。
        let head = chatVM.toolConfirmations.pending.first
        return content.confirmationDialog(
            head.map { titleText(for: $0) } ?? "",
            isPresented: Binding(
                get: { head != nil },
                // ダイアログが外側要因(スワイプ等)で閉じられたら拒否として応答する(宙吊り防止)。
                // 明示ボタンで閉じた場合は先に respond 済みなので、ここでの head は既に別要求 or nil。
                set: { presented in
                    if !presented, let head {
                        chatVM.toolConfirmations.respond(id: head.id, response: .deny)
                    }
                }
            ),
            titleVisibility: .visible,
            presenting: head
        ) { request in
            // アクションは呼ばれた時点の presenting 要求(request)に対して応答する。
            Button("1回だけ許可") {
                chatVM.toolConfirmations.respond(id: request.id, response: .allowOnce)
            }
            Button("常に許可") {
                chatVM.toolConfirmations.respond(id: request.id, response: .allowAlways)
            }
            // 破壊的ツールでなくても「拒否」は取り消し=中止なので .cancel が意味的に近いが、
            // ここでは「実行しない」を明確に選ばせたいので通常ボタンにし、赤字は destructive 警告用に温存。
            Button("拒否", role: .destructive) {
                chatVM.toolConfirmations.respond(id: request.id, response: .deny)
            }
        } message: { request in
            Text(messageText(for: request))
        }
    }

    private func titleText(for request: ToolCallConfirmationRequest) -> String {
        "「\(request.toolName)」を実行しますか?"
    }

    /// サーバー名・破壊的警告・引数要約を数行に畳む。
    private func messageText(for request: ToolCallConfirmationRequest) -> String {
        var lines: [String] = []
        if let server = request.serverName {
            lines.append("サーバー: \(server)")
        }
        // 破壊的 hint がある(または未申告=性悪説で破壊的とみなす)ツールは警告を添える。
        // これは annotations(untrusted hint)を「確認を強める」方向にだけ使う唯一の用途。
        if request.annotations?.isLikelyDestructive ?? true {
            lines.append("この操作は取り消せない変更を行う可能性があります。")
        }
        let args = argumentsSummary(request.argumentsJSON)
        if !args.isEmpty {
            lines.append("引数: \(args)")
        }
        return lines.joined(separator: "\n")
    }

    /// 引数 JSON を数行に丸める(長すぎる JSON でダイアログが破綻しないよう上限を切る)。
    private func argumentsSummary(_ json: String) -> String {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        // 空 object/空文字は「引数なし」として表示を省く。
        if trimmed.isEmpty || trimmed == "{}" { return "" }
        // action sheet の message は長文に弱いので 300 文字で切る(全文は不要——概要が分かればよい)。
        let limit = 300
        if trimmed.count > limit {
            return String(trimmed.prefix(limit)) + "…"
        }
        return trimmed
    }
}

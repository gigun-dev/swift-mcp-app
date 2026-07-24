// R4 許可ゲート(HITL)の実行前確認 UI。ChatViewModel.toolConfirmations.pending の先頭を
// detent セミモーダル(.medium⇔.large)で見せ、ユーザーの選択(1回許可 / 常に許可 / 許可しない)を
// respond(id:response:) へ返す。
//
// 【なぜ detent シートへ作り直したか(旧: confirmationDialog / 素のアクションシート)】
// design/09 決定3。旧実装は action sheet の message が長文に弱く、引数 JSON を 300 字で切って
// 要約表示していた(argumentsSummary)。だが「LLM が今から何をするか」を人が承認するには、
// どんなツールに何の引数を渡すのかを**全文**見られることが本質(claude.ai iOS の承認シートと同じ)。
// detent なら .medium 折り畳みで「ツール名 + ボタン」だけに畳み、上へ引き出す(.large)と
// 引数 JSON 全文 + 破壊警告が展開される。「概要でよい」から「全文が読める」への方針転換なので
// 300 字の切り詰めは廃止した(切り詰めが detent 化の目的と正面から矛盾する)。
//
// 【キュー処理と deny 縮退は現行を維持】並行 tool call で複数要求が同時に積まれても、常に
// pending.first の 1 件だけをシートにする。応答すると先頭が外れ、次があれば pending.first の
// 変化を SwiftUI が検知して自動で次を提示する(item ベースの再提示)。外側要因(スワイプで下げる等)で
// 閉じられたら .deny として応答する(宙吊り防止)——これをやめると Runner の await が解けず
// tool-use ループが固まる。interactiveDismissDisabled は付けない(スワイプ下げ = deny を残す)。
import SwiftUI
import Kernel
import Services

extension View {
    /// チャット本体へ R4 確認シートを載せる。chatVM の確認キューを観測して先頭を提示する。
    /// 呼び出し口(拡張名・引数)は旧 confirmationDialog 版と互換 —— 呼び出し側(ChatHomeView 等)を
    /// 触らずに中身だけ detent シートへ差し替えるための維持。
    func toolConfirmationDialog(chatVM: ChatViewModel) -> some View {
        modifier(ToolConfirmationSheetModifier(chatVM: chatVM))
    }
}

private struct ToolConfirmationSheetModifier: ViewModifier {
    // @Bindable で @Observable な ChatViewModel を観測し、pending の変化で再評価する。
    @Bindable var chatVM: ChatViewModel

    func body(content: Content) -> some View {
        content.sheet(item: presentedRequestBinding) { request in
            ToolConfirmationSheet(request: request) { response in
                // 明示ボタンでの応答。先に respond するので pending.first が次要求(or nil)へ変わり、
                // item binding の get が新しい値を返してシートが自動で閉じる/次を出す。
                // この経路では binding の set(nil) は呼ばれない(SwiftUI の item 変化は set を介さない)ので、
                // onDismiss 相当の deny は打たれない —— 二重応答は起きない。
                chatVM.toolConfirmations.respond(id: request.id, response: response)
            }
        }
    }

    /// sheet(item:) 用の binding。get は常に pending.first(= キューの先頭 = 今提示すべき 1 件)。
    /// set(nil) はユーザーがスワイプ等で外側から閉じたときだけ SwiftUI が呼ぶ —— そのとき先頭要求を
    /// deny で解いて宙吊りを防ぐ。
    private var presentedRequestBinding: Binding<ToolCallConfirmationRequest?> {
        Binding(
            get: { chatVM.toolConfirmations.pending.first },
            set: { newValue in
                // 外側 dismiss(スワイプ下げ等)は item を nil にする。このとき先頭要求はまだ未応答なので
                // deny を返す。明示ボタン経路では上の respond が先に走り set は呼ばれないため、ここは
                // 「ユーザーがボタンを押さずに閉じた」ケースだけを扱う。
                // respond は id 冪等(未知 id は無視)なので、万一二重に走っても先頭を二度 deny するだけで安全。
                guard newValue == nil, let head = chatVM.toolConfirmations.pending.first else { return }
                chatVM.toolConfirmations.respond(id: head.id, response: .deny)
            }
        )
    }
}

/// detent シートの本体。type_body_length/file_length を睨んで modifier から切り出した小さな private View。
/// 見た目は design/09「画面C」= claude.ai iOS の承認シート語彙に合わせる。
private struct ToolConfirmationSheet: View {
    let request: ToolCallConfirmationRequest
    /// 3 ボタンの応答を親(modifier)へ返す。親が respond(id:) を呼ぶ。
    let respond: (ToolCallConfirmationResponse) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // 上の可変領域: 見出し・コネクタ行・引数全文・破壊警告。ここをスクロールさせ、
            // .medium 折り畳みでも下部ボタンが必ず見えるようにする(ボタンは VStack 下部に固定)。
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header
                    connectorRow
                    argumentsBlock
                    if isDestructive {
                        destructiveWarning
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)
            }

            actionButtons
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 20)
        }
        // .medium で「見出し + ボタン」、.large へ引き出すと引数全文が読める(design/09 決定3)。
        .presentationDetents([.medium, .large])
        // グラバー表示。「上へ引き出せる」ことのアフォーダンス。
        .presentationDragIndicator(.visible)
    }

    // MARK: - 部品

    private var header: some View {
        Text("ツールを実行しますか?")
            .font(.title3.weight(.semibold))
            .accessibilityAddTraits(.isHeader)
    }

    /// コネクタ行: `serverName:toolName`(サーバー名が無ければ toolName)を monospaced で。
    /// hand.raised = 承認が必要(design/09 のアイコン語彙 hand に対応。lucide 禁止絵文字の代替に
    /// SF Symbol を使う——絵文字は使わない)。
    private var connectorRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(connectorLabel)
                .font(.callout.monospaced())
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("実行するツール \(connectorLabel)")
    }

    private var connectorLabel: String {
        if let server = request.serverName, !server.isEmpty {
            return "\(server):\(request.toolName)"
        }
        return request.toolName
    }

    /// 引数ブロック: argumentsJSON を整形して全文表示(切り詰めなし)。
    /// 空引数({}・空文字)なら「引数なし」と明示する(旧実装は空だと行を省いていたが、
    /// detent では常に何か見せた方が「引数が空なのか読み込み中なのか」の曖昧さが消える)。
    @ViewBuilder
    private var argumentsBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("引数")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if prettyArguments.isEmpty {
                Text("引数なし")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(prettyArguments)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(Color(.secondarySystemBackground))
                    )
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(prettyArguments.isEmpty ? "引数なし" : "引数 \(prettyArguments)")
    }

    /// 破壊警告: 破壊的ヒントがある(または未申告=性悪説で破壊的とみなす)ときだけ控えめに出す。
    /// annotations(untrusted hint)を「確認を強める」方向にだけ使う唯一の用途——緩和には使わない。
    private var destructiveWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("この操作は取り消せない変更を行う可能性があります。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("警告 この操作は取り消せない変更を行う可能性があります")
    }

    private var isDestructive: Bool {
        // 未申告(annotations なし)も破壊的とみなす(性悪説)。design/09・Kernel の isLikelyDestructive と同じ既定。
        request.annotations?.isLikelyDestructive ?? true
    }

    /// ボタン 3 つ(縦積み・44pt 以上・VoiceOver ラベル付き)。design/09 決定3 の並び。
    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button {
                respond(.allowOnce)
            } label: {
                buttonLabel("1回だけ許可", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("1回だけ許可")

            Button {
                respond(.allowAlways)
            } label: {
                buttonLabel("常に許可", systemImage: "checkmark.circle")
            }
            .buttonStyle(.borderedProminent)
            .accessibilityLabel("このツールを常に許可")

            Button(role: .cancel) {
                respond(.deny)
            } label: {
                buttonLabel("許可しない", systemImage: "nosign")
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("許可しない")
        }
    }

    /// ボタンラベル: 幅いっぱい + 最低 44pt 高(タップ標的の下限)。ラベルは意味対応の SF Symbol 付き
    /// (check=許可 / check-circle=常に許可 / ban(nosign)=許可しない。design/09 のアイコン語彙に対応)。
    private func buttonLabel(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
    }

    /// argumentsJSON を pretty-print する。JSON として解釈できれば整形(キー順ソート・インデント)、
    /// できなければ生文字列をそのまま返す(壊れた/非 JSON でも全文を見せる方針)。
    /// 空 object({})・空文字は空文字を返し、呼び出し側で「引数なし」表示に落とす。
    private var prettyArguments: String {
        let trimmed = request.argumentsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "{}" { return "" }
        guard
            let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data),
            // .sortedKeys でキー順を安定させ、差分を目で追いやすくする(承認判断の助けになる)。
            let pretty = try? JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            ),
            let string = String(data: pretty, encoding: .utf8)
        else {
            // 非 JSON・壊れた JSON でも要約せず生で見せる(全文表示の方針を貫く)。
            return trimmed
        }
        return string
    }
}

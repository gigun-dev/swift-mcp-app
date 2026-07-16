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

    // カード構築に使う AppsServerProxy(T5)。接続共有(設計 §4)。nil の場合はカードを描画しない
    // (proxy 未確立の防御・通常 .ready では非 nil)。
    let proxy: AppsServerProxy?

    // 入力欄のローカル下書き。送信で空にする。View ローカルの @State でよい(VM に持たせる必要なし)。
    @State private var draft: String = ""

    // インラインカードのセッション台帳(InlineCardView.swift 冒頭の「最重要の設計判断」)。
    // @State で1個所有し、チャット画面の生存期間中カード群(webView/session)を生かす。LazyVStack の
    // スクロール再生成に耐えるための外部保持先。
    @State private var cardRegistry = InlineCardRegistry()

    // カード列の実測幅(設計 §5「幅=カード列の実測幅」)。メッセージ列の内側幅を GeometryReader で測り、
    // InlineCardView の containerWidth に渡す。0 の間はカード構築を保留する(InlineCardView 側で guard)。
    @State private var columnWidth: CGFloat = 0

    // 入力欄のフォーカス。キーボードを明示的に閉じる(スクロール dismiss・送信時・タップ外し)ために持つ
    // (ユーザー指摘: TextField から focus を外してもキーボードが出っぱなしだった。@FocusState を
    //  介して inputFocused=false で resignFirstResponder 相当になる)。
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            messages
            Divider()
            composer
        }
        // メッセージ領域をタップしたらキーボードを閉じる(タップ外しでの dismiss・ユーザー指摘)。
        // contentShape で余白タップも拾うが、simultaneousGesture にしてカード/ボタンのタップは妨げない。
        .simultaneousGesture(
            TapGesture().onEnded { inputFocused = false }
        )
    }

    // MARK: - メッセージ列

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(chatVM.turns.enumerated()), id: \.offset) { index, turn in
                        turnView(turn, turnIndex: index)
                            .id(index)
                    }
                }
                // 幅測定は .padding の前に background で行い、カード列の内側幅(パディング差引後)を得る。
                // この幅を InlineCardView の containerWidth に渡し、caldav カードがこの幅にレイアウトする。
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ColumnWidthKey.self, value: geo.size.width)
                    }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 14)
            }
            // チャットのメッセージをスワイプしたらキーボードを対話的に閉じる(iMessage 等の標準挙動・
            // ユーザー指摘のキーボード出っぱなし対策)。
            .scrollDismissesKeyboard(.interactively)
            .onPreferenceChange(ColumnWidthKey.self) { columnWidth = $0 }
            // 末尾ターンの text が伸びる(ストリーミング)たびに最下部へ追従する。
            // turns.count だけでなく末尾 text の長さも監視して、ストリーミング中の追従を効かせる。
            .onChange(of: chatVM.turns.count) { scrollToBottom(proxy) }
            .onChange(of: chatVM.turns.last?.text) { scrollToBottom(proxy) }
        }
        // チャット画面が閉じるとき、カードのセッションをまとめて畳む(設計 §6・§4 の生存はここまで)。
        // スクロールアウトでは畳まない(InlineCardView は onDisappear で teardown しない)。
        .onDisappear { cardRegistry.teardownAll() }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard !chatVM.turns.isEmpty else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo(chatVM.turns.count - 1, anchor: .bottom)
        }
    }

    // MARK: - 1ターン

    @ViewBuilder
    private func turnView(_ turn: ChatTurn, turnIndex: Int) -> some View {
        switch turn.role {
        case .user:
            // ユーザー吹き出し: 右寄せ・青。
            HStack {
                Spacer(minLength: 40)
                bubble(turn.text, isUser: true)
            }
        case .assistant:
            // assistant: ツールステップ列 → 本文吹き出し → インラインカード列(設計 §4)。
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
                // ツール結果の ui:// カード(あれば)。proxy と実測幅が揃っているときだけ描画する。
                // cardID は (turnIndex, cardIndex) で安定(turns/cards は追記のみ)。この ID で
                // registry から同じ host を引くことで、スクロール再生成でも往復状態が保たれる。
                if let proxy {
                    ForEach(Array(turn.cards.enumerated()), id: \.offset) { cardIndex, card in
                        InlineCardView(
                            host: cardRegistry.host(for: "\(turnIndex)-\(cardIndex)"),
                            proxy: proxy,
                            card: card,
                            containerWidth: columnWidth,
                            // スナップショット到達で永続モデルへ書き戻す(T6・設計 §5)。identity は
                            // (turnIndex, cardIndex)。turns/cards は追記のみなのでこの index は安定
                            // (ChatViewModel.setCardSnapshot 側でも範囲外を安全に無視する)。
                            onSnapshot: { html in
                                chatVM.setCardSnapshot(turnIndex: turnIndex, cardIndex: cardIndex, html: html)
                            }
                        )
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
    //
    // タップでリクエスト(argumentsJSON)/レスポンス(resultJSON)を展開できるようにする際、
    // 開閉状態(@State)を行ごとに独立させる必要がある。ChatBodyView は struct View で
    // toolStepRow はただの関数だったため @State を持てず、ForEach の各行が独立した
    // 開閉フラグを持てる小さな行 View(ToolStepRow)に切り出した(タスク指示の「行 View に
    // 切り出すのが素直」に従う)。見た目・配置(HStack + アイコン + 🔧 + ツール名 + ラベル)は
    // 折りたたみ時そのまま踏襲する。
    private func toolStepRow(_ step: ToolCallStep) -> some View {
        ToolStepRow(step: step)
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
                    .focused($inputFocused)  // キーボード dismiss を制御するため focus を束ねる。
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
    /// T7: 分かるときだけ ≈ $X を続けて出す(chatVM.lastCostUSD/cumulativeCostUSD が nil =
    /// 未知モデル or pricing 未ロードのときはコストを一切出さない——トークン数のみ表示は従来どおり。
    /// 設計 §6「嘘の金額を出さない」を厳守。"—" のような偽の埋め草も出さない=単に無い)。
    @ViewBuilder
    private var costHint: some View {
        if let usage = chatVM.lastUsage {
            let total = usage.totalTokens ?? (usage.promptTokens + usage.completionTokens)
            let cumulative = chatVM.cumulativeUsage
            let cumulativeTotal = cumulative?.totalTokens
                ?? cumulative.map { $0.promptTokens + $0.completionTokens }
            HStack(spacing: 8) {
                Text("このターン ≈ \(total.formatted()) tok")
                if let lastCost = chatVM.lastCostUSD {
                    Text(Self.formatUSD(lastCost))
                }
                if let cumulativeTotal {
                    Text("· 累計 \(cumulativeTotal.formatted()) tok")
                }
                if let cumulativeCost = chatVM.cumulativeCostUSD {
                    Text(Self.formatUSD(cumulativeCost))
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
        }
    }

    /// 小額($0.0000 まで見える程度)を出すためのフォーマット。トークン単価は $0.000001/token 級が
    /// 普通(例 gpt-4o-mini 出力 6e-7)なので、NumberFormatter の通貨書式(小数2桁止め)では
    /// ほぼ常に "$0.00" に潰れて情報にならない。`String(format:)` で小数4桁固定にする
    /// (タスク指示「4〜5桁」・4桁を採用: gpt-4o-mini 級の1ターン数百〜数千トークンなら
    /// $0.0001 オーダーまで見えれば十分実用。5桁だと末尾が常に丸めノイズになりやすいため4桁で妥協
    /// ——設計に桁数の明記は無いのでこう解釈)。
    private static func formatUSD(_ value: Double) -> String {
        String(format: "≈ $%.4f", value)
    }

    /// 送信可能条件: 実行中でなく、下書きが空白でない。
    private var canSend: Bool {
        !chatVM.isRunning && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        inputFocused = false  // 送信したらキーボードを閉じる(応答を見やすく・出っぱなし対策)。
        // ChatViewModel.send は throw しない(内部で errorMessage に載せる)。
        Task { await chatVM.send(text) }
    }
}

/// ツールステップ1行(モックの .tool-step)。タップで開閉し、開くと argumentsJSON(リクエスト)/
/// resultJSON(レスポンス)を整形表示する。@State isExpanded を行ごとに持つため、ChatBodyView 本体
/// (struct View で開閉状態を持てない)から切り出した独立行 View。
// internal(private でない)にしているのは、読み取り専用の履歴ビュー(HistoryDetailView)が
// 同じツール req/res 展開行を再利用するため(タスク指示 C-view「ToolStepRow 再利用」)。
struct ToolStepRow: View {
    let step: ToolCallStep
    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            if isExpanded {
                detail
                    .padding(.leading, 20)
                    .padding(.top, 2)
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                // 展開できる合図(chevron)。折りたたみ時は右向き、展開時は下向き。
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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
        }
        .buttonStyle(.plain)
        .padding(.leading, 2)
    }

    /// 展開時の中身。argumentsJSON(リクエスト)/ resultJSON(レスポンス)が nil のセクションは
    /// 出さない(pending/running 中は resultJSON がまだ確定していないので「レスポンス」は出ない)。
    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let args = step.argumentsJSON {
                jsonSection(title: "リクエスト", raw: args)
            }
            if let result = step.resultJSON {
                jsonSection(title: "レスポンス", raw: result)
            }
        }
    }

    private func jsonSection(title: String, raw: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            ScrollView {
                Text(prettyJSON(raw))
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)  // 全文コピー可能に(調査・デバッグ用途)。
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(maxHeight: 240)  // 長い結果に備えて内部スクロール(全体レイアウトを圧迫させない)。
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(.secondarySystemBackground)))
        }
    }

    private func stepStatusLabel(_ state: ToolCallStep.State) -> String {
        switch state {
        case .pending: return "待機中"
        case .running: return "を呼び出し中…"
        case .done: return "完了"
        case .failed: return "失敗"
        }
    }
}

/// JSON 文字列 → pretty print(等幅表示用)。tool_call の引数・結果はどちらも compact JSON
/// 文字列(または失敗時はエラー文言)なので、整形できるものだけ整形し、できない生文字列
/// (エラー文言等)はそのまま返す(タスク指示のヘルパをそのまま踏襲)。
private func prettyJSON(_ raw: String) -> String {
    guard let data = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data),
          let pretty = try? JSONSerialization.data(
            withJSONObject: obj,
            options: [.prettyPrinted, .withoutEscapingSlashes, .sortedKeys]
          ),
          let s = String(data: pretty, encoding: .utf8)
    else { return raw }
    return s
}

/// メッセージ列の内側幅(カード列幅)を GeometryReader → onPreferenceChange で吸い上げる鍵(設計 §5)。
/// 最大値を採る reduce にしておく(複数 reader が競合しても列の実幅に収束する)。
private struct ColumnWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

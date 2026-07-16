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

    // チャット可視領域(ScrollView のビューポート)の高さ(P4-DM・設計 04 §5 H1)。inline の実 maxHeight
    // = floor(可視高 × 0.65)の算出に使う。ScrollView の背景 GeometryReader で測る(background 修飾は
    // コンテンツ全高ではなく ScrollView 自身の frame = ビューポート高になる)。0 の間はフォールバックを使う。
    @State private var visibleHeight: CGFloat = 0

    // fullscreen 昇格の調停役(高々1枚・決定2b・設計 04 §5 H4-C)。@State で1個所有し registry と並置する。
    @State private var fullscreenCoordinator = FullscreenCoordinator()

    /// inline カードの実 maxHeight を可視高から算出する(P4-DM 決定1・設計 04 §5 H1)。
    /// 可視高 × 0.65 を floor。可視高未確定(0)の間はカード構築が columnWidth==0 で保留されるため
    /// フォールバック値(600)は実際にはほぼ使われないが、念のため 0 を避ける。
    private var inlineMaxHeight: CGFloat {
        visibleHeight > 0 ? (visibleHeight * Self.inlineMaxHeightRatio).rounded(.down) : 600
    }

    /// 可視高に対する inline カード上限の比(設計 04 §5 H1・決定1)。spec の例(apps.mdx:616)も
    /// maxHeight:600 と「画面より小さい inline」を示しており、チャットの流れを保つため画面を占有しすぎない
    /// 65% に置く。この値は 1 定数で完全に可逆(§4 可逆性・実機で調整予定 §6-5)。
    private static let inlineMaxHeightRatio: CGFloat = 0.65

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
        // fullscreen カードの sheet(P4-DM・設計 04 §5 H4-E)。item に activeHost をラップした Binding を
        // 渡し、下スワイプ dismiss(item→nil)で coordinator.dismiss()(= host.restoreInline の順序復帰)を呼ぶ。
        .sheet(item: activeHostBinding) { host in
            FullscreenCardView(host: host)
        }
    }

    /// `.sheet(item:)` 用の Binding。get は coordinator.activeHost、set は nil(スワイプ dismiss)で
    /// coordinator.dismiss() を呼ぶ。昇格(非 nil への set)は起きない(昇格は onDisplayModeRequested 経由で
    /// coordinator が activeHost を直接立てるため、この Binding の set には流れてこない)。
    private var activeHostBinding: Binding<InlineCardHost?> {
        Binding(
            get: { fullscreenCoordinator.activeHost },
            set: { newValue in
                // SwiftUI が dismiss で item を nil にしてくる。ここで inline 復帰(rehome → scrollEnabled=false
                // → host-context-changed)を順序どおり実行する(§5 H4-E)。非 nil は来ない想定だが無視して安全。
                if newValue == nil { fullscreenCoordinator.dismiss() }
            })
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
            // 可視領域(ビューポート)の高さを測る(P4-DM・H1)。ScrollView 自身の frame に付く background は
            // コンテンツ全高ではなくビューポート高になるので、ここで inline maxHeight の分母(可視高)が取れる。
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: VisibleHeightKey.self, value: geo.size.height)
                }
            )
            // チャットのメッセージをスワイプしたらキーボードを対話的に閉じる(iMessage 等の標準挙動・
            // ユーザー指摘のキーボード出っぱなし対策)。
            .scrollDismissesKeyboard(.interactively)
            .onPreferenceChange(ColumnWidthKey.self) { columnWidth = $0 }
            .onPreferenceChange(VisibleHeightKey.self) { visibleHeight = $0 }
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
                            host: cardRegistry.host(for: "\(turnIndex)-\(cardIndex)", coordinator: fullscreenCoordinator),
                            proxy: proxy,
                            card: card,
                            containerWidth: columnWidth,
                            maxHeight: inlineMaxHeight,  // 可視高 × 0.65(P4-DM 決定1・H1)。
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
        ToolStepRow(step: step, serverName: serverShortName(from: chatVM.currentSession.serverURL))
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
//
// UX 改善 #2+#4(fable ベスプラ調査・ChatGPT Apps 公式ガイドライン/claude.ai 準拠・ユーザー参照画像):
// 従来は「先頭 chevron で行全体トグル」だったが、ChatGPT/claude.ai は tool-calling 行を
// 「attribution(サーバー・ツールの出自を示す控えめなクローム)+ 右端 `</>` で req/res を開く」
// という形にしている。先頭 chevron は廃止し、開閉の合図を右端の `</>` アイコン一本に統一した
// (合図が2箇所にあると視線が迷う・ユーザー要望「</> を押すと開く」に直結)。
struct ToolStepRow: View {
    let step: ToolCallStep
    /// attribution に出すサーバー短縮名(例 "caldav")。呼び出し側(ChatBodyView/HistoryDetailView)が
    /// それぞれの接続先(ライブ chatVM / 履歴 ChatSession)から導出して渡す(このビュー自身は
    /// 接続情報を持たない=汎用ホストとしての中立性を保つ・CLAUDE.md ビジョン2)。
    let serverName: String
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
        HStack(spacing: 6) {
            // 状態アイコン: running=スピナー / done=チェック / failed=× / pending=時計。
            // attribution の直前に置き、開閉トリガ(右端 `</>`)とは独立して常に見える位置にする。
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

            // attribution: モノグラムバッジ + サーバー短縮名 + "·" + ツール名(claude.ai/ChatGPT の
            // tool-calling 行の見た目に合わせる・ユーザー参照画像)。トーンは secondary 寄りで控えめ。
            attribution

            Spacer(minLength: 4)

            // 右端 `</>`: リク/レス JSON パネルの開閉トリガ(このビュー唯一の開閉合図)。
            codeToggleButton
        }
        .padding(.leading, 2)
        // 行全体タップでも開閉できるようにする(ChatGPT の作法・タスク指示「両方可なら両方」)。
        // contentShape で余白部分もタップ対象にし、Spacer 上のタップも拾う。
        .contentShape(Rectangle())
        .onTapGesture { toggle() }
    }

    /// モノグラムバッジ(角丸四角 + serverName 先頭1字)+ サーバー短縮名 + "·" + ツール名。
    private var attribution: some View {
        HStack(spacing: 5) {
            // モノグラムバッジは装飾(サーバー短縮名テキストと情報が重複する)なので読み上げ対象外にする。
            Text(monogram)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 14, height: 14)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary))
                .accessibilityHidden(true)
            Text(serverName)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("·")
                .font(.caption)
                .foregroundStyle(.secondary)
            // ツール名(モックは code タグで強調していた等幅 + 薄い accent 背景をそのまま踏襲)。
            Text(step.toolName)
                .font(.caption.monospaced())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.14)))
                .foregroundStyle(Color.accentColor)
        }
    }

    /// serverName の先頭1字(例 "caldav" → "c")。空文字なら "?" にフォールバック(壊れた
    /// 入力でもバッジが空白にならないように)。
    private var monogram: String {
        guard let first = serverName.first else { return "?" }
        return String(first).uppercased()
    }

    /// 右端の `</>` 開閉トリガ。展開時は accentColor で塗って「開いている」ことを示し、
    /// 折りたたみ時は secondary の控えめな色にする(タスク指示の色/塗りでの状態表現)。
    private var codeToggleButton: some View {
        Button { toggle() } label: {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.caption)
                .foregroundStyle(isExpanded ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        // 行全体タップの onTapGesture と重複してトグルしないよう、ボタン自身のタップは
        // simultaneousGesture ではなく通常の Button アクションのまま(SwiftUI がボタン領域の
        // タップを優先して親の onTapGesture に伝播させないため、二重トグルは起きない)。
        .accessibilityLabel("リクエスト/レスポンスを表示")
        .accessibilityValue(isExpanded ? "展開中" : "折りたたみ")
        .accessibilityAddTraits(.isButton)
    }

    private func toggle() {
        withAnimation(.easeOut(duration: 0.12)) { isExpanded.toggle() }
    }

    /// 展開時の中身。argumentsJSON(リクエスト)/ resultJSON(レスポンス)が nil のセクションは
    /// 出さない(pending/running 中は resultJSON がまだ確定していないので「レスポンス」は出ない)。
    @ViewBuilder
    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let args = step.argumentsJSON {
                JSONCodeBlock(title: "リクエスト", raw: args)
            }
            if let result = step.resultJSON {
                JSONCodeBlock(title: "レスポンス", raw: result)
            }
        }
    }
}

/// リク/レスの JSON を等幅表示するコードブロック(1つ = リクエスト or レスポンス)。右上に
/// コピーボタンを持つ(ユーザー要望・2026-07-17)。コピー押下で一時的に ✓ に切り替えて
/// フィードバックする(押したことが分かるように・@State copied を各ブロックが個別に持つため
/// ToolStepRow から独立した小ビューに切り出した)。
private struct JSONCodeBlock: View {
    let title: String
    let raw: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                // コピーボタン: prettyJSON(整形後)をペーストボードへ。押下で ✓ に一時切替。
                Button {
                    UIPasteboard.general.string = prettyJSON(raw)
                    copied = true
                    // 1.2s 後に元アイコンへ戻す(短い視覚フィードバック)。
                    Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(copied ? Color.green : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(title)をコピー")
            }
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
}

/// サーバー URL の host 先頭ラベル(例: caldav.gigun-dev.workers.dev → "caldav")を attribution 用に
/// 導出する共有ヘルパ(タスク指示: 導出ロジックは1箇所にまとめて ChatBodyView/HistoryDetailView の
/// 両方から使う)。ロジック自体は ChatHomeView.serverShortName / ChatHistorySidebar.serverShortName と
/// 同一だが、それらは画面固有の入力(serverURLString / ChatHistorySummary)から呼ばれる別関数のため
/// 統合はしていない(過剰共通化を避ける・ここは ToolStepRow 系のみの共有先)。
func serverShortName(from url: URL) -> String {
    guard let host = url.host else { return "MCP" }
    return host.split(separator: ".").first.map(String.init) ?? host
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

/// チャット可視領域(ScrollView ビューポート)の高さを吸い上げる鍵(P4-DM・設計 04 §5 H1)。
/// inline カードの実 maxHeight = floor(可視高 × 0.65)の分母。幅と同じく最大値 reduce にしておく。
private struct VisibleHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

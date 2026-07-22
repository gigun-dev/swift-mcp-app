import SwiftUI
import Kernel
import Services

/// 1ターンの描画。スクロールと入力から、ターン内容・カード・再試行の責務を分離する。
struct ChatTurnView: View {
    let turn: ChatTurn
    let turnIndex: Int
    let chatVM: ChatViewModel
    let cardProxyResolver: (String) -> AppsServerProxy?
    let visibleHeight: CGFloat
    let columnWidth: CGFloat
    let inlineMaxHeight: CGFloat
    let cardRegistry: InlineCardRegistry
    let fullscreenCoordinator: FullscreenCoordinator
    let cardZoom: Namespace.ID
    let haptics: ChatHapticsController

    // MARK: - 1ターン

    @ViewBuilder
    var body: some View {
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
                // 【思考中インジケータ(ユーザー実機 FB 2026-07-17「送信しても下に何も出ない」への対処)】
                // tool-use ループは各周で「空テキストの assistant ターンを先に append → ストリームを待つ」
                // (ChatViewModel.send)。その待ち時間、このターンは text も toolSteps も cards も空で、
                // 上の描画はすべて条件で隠れる=**吹き出しゼロの不可視 VStack**になる。速い回線では最初の
                // トークンが ~1s で来るので見えないが、低速/初トークンが遅い回線(実機セルラー等)では
                // 「ユーザー発話の下に何も出ない・スピナーも無い・エラーも無い」状態が長く続き、送信が
                // 死んだように見える(実機 FB の症状に一致)。ここで「まだ何も描くものが無い実行中ターン」に
                // 限って明示のインジケータを出し、その空白を埋める。
                // 条件: 実行中(isRunning)/ 末尾ターン / text・toolSteps・cards すべて空。
                //  - 末尾ターン限定: 過去の(確定済みで偶々空文字の)assistant ターンには出さない。
                //  - 3要素とも空限定: 1つでも描くものが出た瞬間に自動で消える(スピナー行・本文・カードが
                //    出れば「待ち」ではないため)。isRunning が false になれば当然消える(取り残し防止)。
                if chatVM.isRunning
                    && turnIndex == chatVM.turns.count - 1
                    && turn.text.isEmpty
                    && turn.toolSteps.isEmpty
                    && turn.cards.isEmpty {
                    thinkingIndicator
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
                //
                // 【2026-07-18 実機バグ根治: visibleHeight > 0 も構築ゲートへ追加】従来は
                // InlineCardView 側で containerWidth > 0(columnWidth 実測済み)だけを構築ゲートに
                // していたが、inlineMaxHeight(可視高×0.65)は visibleHeight===0 のときフォールバック
                // 600 を返す(inlineMaxHeight の doc コメント)。columnWidth の PreferenceKey
                // (ColumnWidthKey・メッセージ列内側の background)が VisibleHeightKey
                // (ScrollView 自身の background)より先に反映される SwiftUI の更新順は保証されておらず、
                // 実機ではその順で発火することがあった — columnWidth 確定時点で visibleHeight がまだ 0 の
                // まま InlineCardView.buildIfNeeded が走り、フォールバック 600 が
                // AppsBridgeSession.maxHeight(immutable let)に焼き付く。以後 visibleHeight が正しい値
                // (iPhone 12 mini 実機で ≈400)に更新されても、buildIfNeeded は buildTask!=nil で
                // no-op のため再送されず、カード(todos-app.ts)は誤って maxHeight=600 で fold 判定する。
                // 未完了5件(due/メモ込みで可変高)は 600 未満に収まるため fold されず、しかしホスト側の
                // 実クランプは 400 前後なので下端の + FAB が物理的にクリップされ押せなくなる(実機再発の
                // 真因)。fold.ts/todos-entry.ts 側の畳みロジック自体は正しく動いており、渡された
                // maxHeight が実態と乖離していたのが根治点 —— columnWidth と同じ「実測前は保留」の扱いを
                // visibleHeight にも及ぼし、両方揃うまでカード構築(=ui/initialize の maxHeight 確定)を
                // 遅らせる。
                if visibleHeight > 0 {
                    ForEach(Array(turn.cards.enumerated()), id: \.offset) { cardIndex, card in
                        // カード由来サーバーの proxy を前置ツール名から解決する(M2・タスク指示 §4)。
                        // 解決できない(未知 prefix / 切断済みサーバー)カードは描画しない。
                        if let proxy = cardProxyResolver(card.toolName) {
                        // host を先に束ねる: zoom source の id(host.id)を InlineCardView 本体と
                        // .matchedTransitionSource の両方に使うため(call site で参照が要る)。
                        // 【混線バグ修正(原因B・防御的多重化)】キーに resourceUri を含める。
                        // 従来は "(turnIndex)-(cardIndex)" のみ = **ツールの同一性を含まない
                        // 位置キー**だった。ChatHomeView 側で `.id(chatVM.currentSession.id)` を
                        // 足してセッション跨ぎの混線(実機で踏んだ経路)は塞いだが、それは
                        // 「View identity が変わればどのみち registry ごと作り直る」という
                        // 外側の防御であり、registry 自体は今後も位置キーのままでは
                        // 同種の事故(将来 retry のピンポイント削除実装・巻き戻し後の再送で
                        // 同じ index に別ツールが来るケース等)に弱い。URI を key に混ぜておけば、
                        // 万一 index が一致しても内容(ツール)が違えば別 host になり、
                        // 誤って旧 webView/HTML を再利用することがなくなる(get-or-create の
                        // 「同一」の定義を「位置」から「位置+内容」へ強めるだけで、
                        // 正常系(同じ card が同じ index に来る通常のスクロール再描画)は
                        // 従来どおり同一 host を引き続ける)。
                        let host = cardRegistry.host(
                            for: "\(turnIndex)-\(cardIndex)-\(card.resourceUri)",
                            coordinator: fullscreenCoordinator
                        )
                        // カード内操作(done/undo 等の tools/call)の触覚を配線(ユーザー要望 2026-07-17)。
                        // body 評価のたびに同じ closure を再代入するが冪等・軽量(ChatHaptics.cardAction 参照)。
                        // ViewBuilder 内では `_ =` が Void 式として拒否されるため、discardable-let を意図的に使う。
                        // swiftlint:disable:next redundant_discardable_let
                        let _ = { host.onCardToolCall = { haptics.cardAction() } }()
                        InlineCardView(
                            host: host,
                            proxy: proxy,
                            card: card,
                            containerWidth: columnWidth,
                            maxHeight: inlineMaxHeight,  // 可視高 × 0.65(P4-DM 決定1・H1)。
                            // スナップショット到達で永続モデルへ書き戻す(T6・設計 §5)。identity は
                            // (turnIndex, cardIndex)。turns/cards は追記のみなのでこの index は安定
                            // (ChatViewModel.setCardSnapshot 側でも範囲外を安全に無視する)。
                            // 【監査 2026-07-18 LOW】card.resourceUri をこの時点(body 評価時)で
                            // closure に閉じ込めて渡す——onSnapshot は非同期に(size-changed 到達や
                            // teardown を合図に)後から呼ばれるため、呼ばれた時点で同じ index に
                            // 別カードが来ている可能性を setCardSnapshot 側で検証できるようにする。
                            onSnapshot: { html in
                                chatVM.setCardSnapshot(
                                    turnIndex: turnIndex,
                                    cardIndex: cardIndex,
                                    expectedResourceUri: card.resourceUri,
                                    html: html
                                )
                            }
                        )
                        // zoom source アンカー(拡大の起点=この inline カード枠)。destination の
                        // .zoomTransition(id: host.id) と同じ id/namespace で「その場から拡大」になる。
                        // iOS 18+ でのみ効き、未満では no-op。
                        .zoomSource(id: host.id, in: cardZoom)
                        }  // if let proxy = cardProxyResolver(...)
                    }
                }
                // 再生成(retry・ユーザー要望 2026-07-17)。末尾 assistant ターンにだけ出す(ChatGPT 式)。
                // エラー時(chatVM.errorMessage 非 nil)もこの分岐を通る——エラーで打ち切られたターンも
                // 「末尾の assistant ターン」であることに変わりなく、同じボタンがそのまま
                // 「エラーからの再試行」導線を兼ねる(専用のエラー UI を別に作らずに済む)。
                if !chatVM.isRunning && turnIndex == chatVM.turns.count - 1 {
                    retryButton
                }
            }
            // ツールステップの完了/失敗ハプティクス(ChatHaptics.swift・ユーザー要望 2026-07-17)。
            // turn.toolSteps の変化を (oldValue, newValue) で受け取り、失敗/完了の判定は
            // ChatHapticsController 側の diff ロジックに委ねる(この View は配線のみ)。VStack 全体への
            // 修飾子として付け直した(ViewBuilder のコンテンツ列の途中に置くと構文エラーになるため)。
            .onChange(of: turn.toolSteps) { old, new in
                haptics.toolSteps(didChangeFrom: old, to: new)
            }
        case .system, .tool:
            // system / tool は wire 専用でありターン表示には現れない(ChatViewModel は
            // turns に user/assistant しか積まない)。将来のために握りつぶさず何も出さない。
            EmptyView()
        }
    }

    /// 思考中インジケータ(実行中で、まだ何も描くものが無い assistant ターンに出す・上の呼び出し箇所参照)。
    /// 初回の textDelta / toolStep / card が出れば呼び出し側の条件が外れて自動的に消える。
    /// 【2026-07-17 ユーザー FB で改訂】初版は「spinner +『考え中…』テキストの吹き出し」だったが、
    /// 「ChatGPT みたいな、丸のインジケータが縮小拡大するアニメーションがいい」との裁定で
    /// **息をする丸(pulsing dot)**へ変更。吹き出し枠もテキストも無し — 「本文が現れる場所で
    /// 小さな丸が脈打つ」だけの控えめな表現(枠があると「空メッセージが来た」ように見える)。
    /// ボツ案: 3点リーダー(typing indicator)は iMessage の「相手が入力中」の語彙で意味がズレる。
    private var thinkingIndicator: some View {
        ThinkingPulseDot()
            .padding(.horizontal, 6)
            .padding(.vertical, 8)
            // アクセシビリティ: 読み上げに「応答を生成中」を伝える(視覚のみに依存しない)。
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("応答を生成中")
    }

    /// 再生成ボタン(retry・ユーザー要望 2026-07-17)。ChatGPT 式に控えめな丸矢印1個のみ
    /// (「送信」ボタンのような主張はしない・タスク指示)。タップ領域は 28×28 を contentShape で確保する
    /// (アイコン自体は .caption サイズで小さいため、指のタップ精度に対して見た目より広い当たり判定が必要)。
    private var retryButton: some View {
        Button {
            haptics.sent()  // 送信と同じ軽い合図(タスク指示・「もう一度投げる」操作として自然)。
            // 【なぜ teardownAll(全カード畳み)にしたか(タスク指示で裁量とされた点・ボツ案を残す)】
            // retry は「最後の user ターン以降」を丸ごと巻き戻す(ChatViewModel.retryLastTurn)。
            // このとき削除される turns に紐づく CardEmbed も消える。registry のキーは
            // 2026-07-18 の混線バグ修正で resourceUri を含めたため(上の host(for:) 呼び出し
            // コメント参照)、同じ index に別ツールが来ても host 取り違えは起きなくなったが、
            // それでも teardownAll を維持するのは「巻き戻された過去カードの WKWebView/
            // AppsBridgeSession を retry のたびに律儀に生かし続ける理由が無い」ため
            // (低頻度操作・作り直しコストは小さい)。もしピンポイント削除
            // (該当 turnIndex 以降のキーだけ teardown)にとどめる場合でも、今は key に
            // resourceUri が要るため単純な turnIndex プレフィックス走査では済まない
            // (「host(for:) が index 一致だけで取り違える」という旧来の懸念自体は解消済み)。
            // ピンポイント削除も不可能ではない(registry に「turnIndex プレフィックスで選択削除」
            // API を足せばよい)が、retry は低頻度操作であり、巻き戻されない過去ターンのカードも
            // host(for:) がオンデマンドで作り直す(InlineCardHost.swift の InlineCardRegistry.host(for:)
            // は get-or-create なので、teardownAll 後に dict が空になっても次の描画で新しい
            // InlineCardHost が生成され buildIfNeeded が再構築する)ため、実害は「過去カードの
            // WKWebView が一瞬作り直しになる(往復状態が飛ぶ)」程度に留まる。キー走査 API を
            // 足す複雑さより、全畳みの単純さ・安全さを優先した(ボツ案として残す)。
            cardRegistry.teardownAll()
            chatVM.submitRetry()
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("応答を再生成")
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
        // ツール名は前置形(slug__tool)で積まれる(M2)。attribution には slug を「サーバー名」として
        // 出し、ツール名からは前置を剥がして元の名前を見せる(前置形のままだと読みにくい)。前置が無い
        // (旧データ・単一サーバー)場合は従来どおり接続先 URL からサーバー短縮名を導く。
        let parsed = ToolNamespacing.parse(prefixed: step.toolName)
        let serverLabel = parsed?.slug ?? serverShortName(from: chatVM.currentSession.serverURL)
        var display = step
        if let parsed { display.toolName = parsed.tool }
        return ToolStepRow(step: display, serverName: serverLabel)
    }
}

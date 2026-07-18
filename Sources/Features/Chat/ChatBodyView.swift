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

    // カード拡大の zoom トランジション用 namespace(P4-DM 遷移アニメ・設計 04 §5 決定2 2026-07-17 追更新の
    // 改訂: 自前 overlay スナップショットズームは高依存でボツ→財産、iOS 18 公式 zoom transition を採用)。
    // source(inline カード)と destination(fullScreenCover 中身)を同じ id で結ぶと「カード rect →
    // 全画面 rect へその場から拡大/縮小」が得られる。id は host.id(ObjectIdentifier・高々1枚昇格なので衝突なし)。
    // iOS 17 は fullScreenCover の遷移差し替えが公開 API 上不可 → 下の zoomSource/zoomTransition 拡張が
    // #available で既定カバー(下からせり上がり)にフォールバックする(⤢ メタファ不整合は iOS 17 のみ残るが
    // 授業/提出想定は iOS 18 実機で、既定挙動より劣化させない範囲で許容・§4 可逆)。
    @Namespace private var cardZoom

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

    /// ↓ ボタンを出すためのスクロールアップしきい値(px)。ビューポート下端より下にこの量以上の
    /// コンテンツが隠れて初めてボタンを出す(ユーザー FB「出るのが早すぎる」への対処)。可視高の 0.4 倍
    /// (端末非依存)を採り、下限 200 で小型端末でも実用的な遊びを残す。値は体感チューニング用に可逆
    /// (小さいほど早く出る・0 にすると旧来の 1px 相当)。
    private var scrollJumpThreshold: CGFloat {
        max(200, visibleHeight * 0.4)
    }

    // 入力欄のフォーカス。キーボードを明示的に閉じる(スクロール dismiss・送信時・タップ外し)ために持つ
    // (ユーザー指摘: TextField から focus を外してもキーボードが出っぱなしだった。@FocusState を
    //  介して inputFocused=false で resignFirstResponder 相当になる)。
    @FocusState private var inputFocused: Bool

    // ハプティクフィードバック役(ChatHaptics.swift・ユーザー要望 2026-07-17)。画面の生存期間中
    // 1個を保持して generator を使い回す(prepare() の効果を活かすため・ChatHapticsController 冒頭コメント参照)。
    @State private var haptics = ChatHapticsController()

    // 最下部にいるか(ChatGPT の ↓ フローティングボタンの出し分け・タスク指示2)。
    // LazyVStack 末尾に置いた不可視センチネルの onAppear/onDisappear で切り替える(iOS 17 で動く素直な
    // 「最下部検出」)。ボツ案: onScrollGeometryChange での offset 監視は iOS 18+ のため却下(iOS 17 優先)。
    // 初期 true(空/1画面に収まるうちはボタンを出さない)。
    @State private var isAtBottom: Bool = true

    // 送信アンカーのアニメを抑制するか(アクセシビリティ「視差効果を減らす」)。位置決め自体は残す。
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 送信した user ターンを寄せる先のアンカー(x=中央・y=上端起点)。ChatGPT 風の「上部に少し余白」は
    /// まず LazyVStack の上 padding で担う。足りなければ y を 0.02〜0.05 に上げる(1定数・可逆・実機調整)。
    private static let userTurnAnchor = UnitPoint(x: 0.5, y: 0.0)

    var body: some View {
        VStack(spacing: 0) {
            messages
            Divider()
            composer
        }
        // 画面表示直後に generator を prepare しておく(最初の発火遅延を減らす)。
        .task { haptics.prepareAll() }
        // メッセージ領域をタップしたらキーボードを閉じる(タップ外しでの dismiss・ユーザー指摘)。
        // contentShape で余白タップも拾うが、simultaneousGesture にしてカード/ボタンのタップは妨げない。
        .simultaneousGesture(
            TapGesture().onEnded { inputFocused = false }
        )
        // fullscreen カードの器(P4-DM・設計 04 §5 決定2・2026-07-17 更新: sheet→fullScreenCover)。
        // item に activeHost をラップした Binding を渡し、⤡ による dismiss(item→nil)で
        // coordinator.dismiss()(= host.restoreInline の順序復帰)を呼ぶ。sheet(.large)は「上余白 dead 領域・
        // ⤢ 拡大メタファとボトムシートの不整合・スクロール前提なら全画面が素直」でユーザー却下 → 全画面に。
        .fullScreenCover(item: activeHostBinding) { host in
            // destination 側 zoom アンカー: source(inline カード)と同じ id/namespace で結ぶ。
            // iOS 18+ でのみ .navigationTransition(.zoom) が効き、それ未満では no-op(既定カバー)。
            FullscreenCardView(host: host)
                .zoomTransition(id: host.id, in: cardZoom)
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
                    // 最下部センチネル(不可視・高さ 1)。↓ ボタンのタップ先(scrollTo("bottom-sentinel"))
                    // 兼、「最下部からどれだけ離れているか」の距離測定点。実コンテンツの直後(スペーサーの前)に
                    // 置くことで、距離 0 =「最後のメッセージの底が画面下端に来ている」を意味する。
                    // 【2026-07-17 ユーザー FB「矢印が出るのが早すぎる」への対処 — 1px 可視判定 → しきい値距離へ】
                    // 初版は onAppear/onDisappear の単純な可視判定で、センチネルが 1px でも外れた瞬間に
                    // ボタンが出た(= 少しスクロールしただけで出る)。ChatGPT/iMessage/Slack のベスプラは
                    // 「一定量スクロールアップして初めて出す」しきい値方式。ScrollView に名前付き座標空間を張り、
                    // このセンチネルの maxY をその空間で測って「ビューポート下端からどれだけ下にあるか
                    // (= まだ見えていないコンテンツ量)」を求め、しきい値超えでだけボタンを出す(iOS 17 で動く
                    // 素直な手法。onScrollGeometryChange は iOS 18+ なので使わない)。
                    Color.clear
                        .frame(height: 1)
                        .id("bottom-sentinel")
                        .background(
                            GeometryReader { geo in
                                Color.clear.preference(
                                    key: BottomSentinelYKey.self,
                                    value: geo.frame(in: .named("chatScroll")).maxY)
                            })
                    // 末尾の予約スペース(ChatGPT 式アンカーの前提条件)。scrollTo(.top) で「送信した
                    // user メッセージを画面最上部へ」動かすには、その下にビューポート分のスクロール余地が
                    // 必要になる(余地が無いと最下部で頭打ちになり user メッセージが中途半端な位置で止まる)。
                    // AI の返事がまだ短いうちからでも user メッセージを天井まで運べるよう、可視高相当の
                    // 余白を末尾に確保する。返事が伸びればこの余白は実コンテンツに置き換わっていく格好。
                    // 【v1 の割り切り(親へ報告)】会話完了後もこの余白は残り、最下部までスクロールすると
                    // 空白が見える。ChatGPT web も同様の余地を持つため許容するが、完了後に畳む最適化は
                    // 未実装(visibleHeight>0 のときだけ確保し、レイアウト確定前は 0)。
                    // 【順序】センチネルより**後**に置く(センチネルの位置修正コメント参照)。
                    if visibleHeight > 0 && !chatVM.turns.isEmpty {
                        Color.clear.frame(height: visibleHeight * 0.85)
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
            // ↓ ボタンのしきい値判定用の座標空間(上の BottomSentinelYKey コメント参照)。センチネルの
            // maxY をこの空間で測ると、スクロールに応じて値が動く(最下部で ≈ 可視高、上へスクロールすると
            // それより大きくなる)ので、差分でビューポート下端からの距離が取れる。
            .coordinateSpace(name: "chatScroll")
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
            // ↓ ボタンの出し分け(しきい値方式・ユーザー FB「出るのが早すぎる」)。センチネル maxY と
            // 可視高の差 = ビューポート下端から下に隠れているコンテンツ量。これが scrollJumpThreshold を
            // 超えたときだけ「最下部でない」= ボタンを出す。1画面弱スクロールしないと出ないので、最下部
            // 付近の微小スクロールでチラつかない(ChatGPT 等の体感に合わせる)。visibleHeight 未確定(0)や
            // 差が負(レイアウト過渡)のときは最下部扱いにしてボタンを出さない(誤出現を避ける安全側)。
            .onPreferenceChange(BottomSentinelYKey.self) { sentinelMaxY in
                guard visibleHeight > 0 else { isAtBottom = true; return }
                let hiddenBelow = sentinelMaxY - visibleHeight
                isAtBottom = hiddenBelow <= scrollJumpThreshold
            }
            // 【ChatGPT 式スクロールアンカー(2026-07-17 再設計・Fable)】送信した user メッセージを画面
            // 上部へ寄せ、AI の返事はその下へ流れ込む(ストリーミング中は強制追従しない)。
            // 旧実装は `onChange(of: turns.count)` + `turns.last?.role == .user` ガードで送信を推測していたが、
            // send() が user append 直後に空 assistant ターンも append するため、onChange 発火時には
            // turns.last が常に .assistant になり **一度もスクロールしなかった**(ChatViewModel.lastSubmission
            // の宣言コメントに機序)。配列の形からの推測をやめ、VM が記録した送信イベント(lastSubmission)を
            // 直接観測する。seq により retry(同一 index 再送)でも確実に発火する。
            .onChange(of: chatVM.lastSubmission) { _, submission in
                guard let submission else { return }
                // 1拍遅延: この onChange は user/assistant の append を含むトランザクションで発火するが、
                // その時点では LazyVStack が対象行を遅延生成し終えておらず、同一 runloop の scrollTo は
                // 着地がズレる/対象未生成で失敗しうる。main queue に1拍逃がしてレイアウト確定後に打つ
                // (二度打ちは既定では入れない — 実機で着地ズレが出たら +50ms の2発目を足す方針・可逆)。
                DispatchQueue.main.async {
                    anchorSubmittedTurn(submission.turnIndex, proxy: proxy)
                }
            }
            // ストリーミング tick(ChatGPT アプリ風の刻まれてる感・ユーザー要望 2026-07-17)。
            // かつて scrollToBottom と同じ観測点(末尾ターンの text 伸長)に相乗りしていた。スクロール追従は
            // 廃止したが、tick の観測点はそのまま残す(削るのはスクロールだけ・タスク指示)。streamingThrottle が
            // 実際に鳴らすかは内部で判定するので、ここでは間引かず素直に毎回呼ぶ。
            .onChange(of: chatVM.turns.last?.text) { haptics.streamingTick() }
            // inline カード内の focus 要素がキーボードに隠れる問題への対処(InlineCardKeyboardAvoider・
            // ユーザー実機 FB 2026-07-17)。keyboardWillShow を横流しするだけ(座標解決・スクロールは
            // avoider が UIKit グローバルから辿って行う)。fullscreen カードや通常 TextField 入力は
            // avoider 側のガードで対象外になる。
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                InlineCardKeyboardAvoider.handleKeyboardWillShow(note)
            }
            // ↓ フローティングボタン(ChatGPT の scroll-to-bottom 相当・タスク指示2)。最下部にいない
            // ときだけ半透明で出し、タップで最下部センチネル(=その時点のコンテンツの一番下)へ寄せる。
            // 強制追従を廃止した代わりに「読み終えたら手動で最新へ戻る」導線を1つ用意する(読み位置を奪わない)。
            // 【2026-07-17 ユーザー FB で右下 → 左右中央へ】ChatGPT 本家は中央下。右下は inline カードの
            // ⤢ や入力欄の送信ボタンと同じ側で導線が渋滞する、という点でも中央が良い。
            .overlay(alignment: .bottom) {
                if !isAtBottom {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("bottom-sentinel", anchor: .bottom)
                        }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().stroke(Color(uiColor: .separator)))
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 10)
                    .transition(.opacity)
                    .accessibilityLabel("最新のメッセージへ")
                }
            }
        }
        // チャット画面が閉じるとき、カードのセッションをまとめて畳む(設計 §6・§4 の生存はここまで)。
        // スクロールアウトでは畳まない(InlineCardView は onDisappear で teardown しない)。
        .onDisappear { cardRegistry.teardownAll() }
    }

    /// 送信された user ターン(index 指定)を画面上部へ寄せる(ChatGPT 式・2026-07-17 再設計・Fable)。
    /// トリガは chatVM.lastSubmission の観測(上の onChange)。ツール実行・カード出現・ストリーミング
    /// text 伸長では lastSubmission は変わらないので呼ばれない = 読み位置を奪わない。
    ///
    /// - 遅延実行(DispatchQueue.main.async)経由で呼ばれるため、その間に retry 等で turns が縮んで
    ///   index が範囲外になる可能性がある。実行時ガードで安全に無視する(スクロールしそこねても壊れない)。
    /// - anchor は Self.userTurnAnchor(上部・y=0 起点)。LazyVStack の上 padding(14)が「上端ぴったり」を
    ///   少し和らげるので、ChatGPT 風の「上部に少し余白」はまず padding で足りる想定(足りなければ
    ///   userTurnAnchor.y を 0.02〜0.05 に上げる・1定数で可逆・実機調整項目)。
    /// - reduce-motion 時はアニメ無しで即時に位置決めする(位置合わせは機能なので省かない・動きだけ消す)。
    private func anchorSubmittedTurn(_ index: Int, proxy: ScrollViewProxy) {
        guard chatVM.turns.indices.contains(index) else { return }
        if reduceMotion {
            proxy.scrollTo(index, anchor: Self.userTurnAnchor)
        } else {
            withAnimation(.easeOut(duration: 0.25)) {
                proxy.scrollTo(index, anchor: Self.userTurnAnchor)
            }
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
                if let proxy {
                    ForEach(Array(turn.cards.enumerated()), id: \.offset) { cardIndex, card in
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
                            coordinator: fullscreenCoordinator)
                        // カード内操作(done/undo 等の tools/call)の触覚を配線(ユーザー要望 2026-07-17)。
                        // body 評価のたびに同じ closure を再代入するが冪等・軽量(ChatHaptics.cardAction 参照)。
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
                            onSnapshot: { html in
                                chatVM.setCardSnapshot(turnIndex: turnIndex, cardIndex: cardIndex, html: html)
                            }
                        )
                        // zoom source アンカー(拡大の起点=この inline カード枠)。destination の
                        // .zoomTransition(id: host.id) と同じ id/namespace で「その場から拡大」になる。
                        // iOS 18+ でのみ効き、未満では no-op。
                        .zoomSource(id: host.id, in: cardZoom)
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
            Task { await chatVM.retryLastTurn() }
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
        haptics.sent()  // 送信確定の軽い合図(タスク指示 2)。
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
            // コピーボタンはグレーブロックの**内部右上**にオーバーレイする(ユーザー要望 2026-07-17:
            // タイトル行でなくコード塊の右上が自然)。iOS は hover が無いので常時表示だが、
            // 半透明 material の小さな丸背景で JSON テキストの上でも視認でき、かつ主張しすぎない。
            .overlay(alignment: .topTrailing) { copyButton }
        }
    }

    /// prettyJSON(整形後)をペーストボードへコピーする小ボタン。押下で 1.2s だけ ✓ に切替。
    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = prettyJSON(raw)
            copied = true
            Task { try? await Task.sleep(for: .seconds(1.2)); copied = false }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
                .foregroundStyle(copied ? Color.green : Color.secondary)
                .padding(5)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .padding(4)  // ブロック角から少し離す。
        .accessibilityLabel("\(title)をコピー")
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

// MARK: - zoom トランジション(P4-DM 遷移アニメ・設計 04 §5 決定2 2026-07-17 改訂)
//
// iOS 18 の zoom transition(matchedTransitionSource + navigationTransition(.zoom))を薄くラップする。
// source(inline カード)と destination(fullScreenCover 中身)を同じ (id, namespace) で結ぶと、
// カード枠 rect ↔ 全画面 rect の「その場から拡大/縮小」遷移が公式に得られる(⤢=拡大メタファに一致)。
// iOS 17 は fullScreenCover の遷移差し替えが公開 API 上不可なので #available で no-op に落とし、
// 既定のカバー(下からせり上がり)にフォールバックする(遷移だけの差で機能は同一・§4 可逆)。
// 自前 overlay スナップショットズーム(旧案)は Web プロセス再レイアウト飛行のコスト・自前提示機構の
// 高依存でボツ=財産(設計 04 §5 の 2026-07-17 追更新ブロック参照)。id は host.id(ObjectIdentifier)。
private extension View {
    /// 拡大の起点(inline カード枠)に付ける source アンカー。
    @ViewBuilder
    func zoomSource(id: ObjectIdentifier, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.matchedTransitionSource(id: id, in: namespace)
        } else {
            self  // iOS 17: 差し替え不可 → 既定カバー遷移のまま。
        }
    }

    /// 拡大の着地先(fullScreenCover 中身)に付ける destination アンカー。source と同 id/namespace で対応。
    @ViewBuilder
    func zoomTransition(id: ObjectIdentifier, in namespace: Namespace.ID) -> some View {
        if #available(iOS 18.0, *) {
            self.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
    }
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

/// 最下部センチネルの maxY を "chatScroll" 座標空間で吸い上げる鍵(↓ ボタンのしきい値判定・上記コメント)。
/// スクロール位置に応じて動く値なので、幅/可視高のような「最大値 reduce」ではなく最後の値をそのまま採る
/// (センチネルは1個だけなので nextValue が実質そのまま最新値になる)。
private struct BottomSentinelYKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// ChatGPT 式の「息をする丸」(2026-07-17 ユーザー裁定・thinkingIndicator のコメント参照)。
/// 直径 12pt の丸が 0.55⇄1.0 のスケールと薄い⇄濃いの opacity を ~0.9s 周期で往復する。
/// 値は ChatGPT iOS の見た目の近似(正確な仕様は非公開なので目視合わせ・1定数ずつ可逆)。
/// prefers-reduced-motion(SwiftUI は accessibilityReduceMotion)ではアニメを止めて静止した丸のみ。
private struct ThinkingPulseDot: View {
    @State private var pulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Circle()
            .fill(Color.primary.opacity(pulsing ? 0.85 : 0.35))
            .frame(width: 12, height: 12)
            .scaleEffect(pulsing ? 1.0 : 0.55)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.45).repeatForever(autoreverses: true),
                value: pulsing
            )
            .onAppear { pulsing = true }
    }
}

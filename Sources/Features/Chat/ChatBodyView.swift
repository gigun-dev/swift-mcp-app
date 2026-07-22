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

    // カード由来サーバーの proxy を前置ツール名(slug__tool)から解決する(M2・タスク指示 §4)。
    // カードは「そのツールを実行したサーバー」の proxy で tools/call・resources/read を流す必要がある
    // (複数サーバー同時接続では単一 proxy 前提が崩れる)。ChatHomeViewModel.cardProxy(forToolName:) を
    // ここへ渡す。nil を返すツール(未知 prefix・切断済みサーバー)はカードを描画しない。
    let cardProxyResolver: (String) -> AppsServerProxy?

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
    /// 可視高 × 0.65 を floor。
    /// 【2026-07-18 訂正: フォールバック 600 は「ほぼ使われない」ではなく実際に構築に焼き付いていた】
    /// 旧コメントは「columnWidth==0 で保留されるため実際にはほぼ使われない」と書いていたが、実際の
    /// 構築ゲート(InlineCardView.task(id: containerWidth>0))は containerWidth だけを見ており
    /// visibleHeight を見ていなかった。columnWidth の PreferenceKey が visibleHeight のそれより先に
    /// 反映される SwiftUI 更新順が実機で起き、フォールバック 600 が AppsBridgeSession.maxHeight
    /// (immutable)に焼き付いて inline カードの畳み判定を壊すバグを引いた(todos カード FAB クリップ
    /// 再発・fold.ts/todos-entry.ts 側は無罪)。呼び出し側(ChatBodyView.body の `if let proxy,
    /// visibleHeight > 0`)で構築自体を visibleHeight > 0 までブロックしたため、この関数が
    /// フォールバックを返す状況では実際に子カードは1枚も構築されない(0 を避ける安全策としてのみ残す)。
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
            ChatComposerView(
                chatVM: chatVM,
                draft: $draft,
                inputFocused: $inputFocused,
                haptics: haptics
            )
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
            }
        )
    }

    // MARK: - メッセージ列

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(chatVM.turns.enumerated()), id: \.offset) { index, turn in
                        ChatTurnView(
                            turn: turn,
                            turnIndex: index,
                            chatVM: chatVM,
                            cardProxyResolver: cardProxyResolver,
                            visibleHeight: visibleHeight,
                            columnWidth: columnWidth,
                            inlineMaxHeight: inlineMaxHeight,
                            cardRegistry: cardRegistry,
                            fullscreenCoordinator: fullscreenCoordinator,
                            cardZoom: cardZoom,
                            haptics: haptics
                        )
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
                                    value: geo.frame(in: .named("chatScroll")).maxY
                                )
                            }
                        )
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
            // 【2026-07-18 fullscreen ズームの「中心が右上へ流れる」ブレへのガード】fullscreen 昇格中
            // (activeHost 非 nil)は avoider を発火させない。昇格フロー(折り畳み + → fullscreen →
            // ドラフト行 focus)ではキーボード出現がズーム遷移と同時に走り、avoider がチャットを
            // スクロールすると **zoom transition の source(インラインカード)の矩形が飛行中に動く** →
            // システムの spring が再ターゲットして最大化の中心軸がズレる、という機序の一因を断つ。
            // fullscreen 中は WKWebView の内部スクロール+標準のキーボード回避が効くので avoider 不要。
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { note in
                guard fullscreenCoordinator.activeHost == nil else { return }
                InlineCardKeyboardAvoider.handleKeyboardWillShow(note)
            }
            // 【2026-07-18 実機 FB「追加(ドラフト)行がキーボードに隠れる」の二段構え】WillShow 時点は
            // SwiftUI の下端インセット付与前でスクロール上限が過小になりうる(avoider 側でも将来分を
            // 織り込むよう改訂したが、レイアウト系のタイミングは端末/OS 差が残る)。DidShow(キーボード
            // 提示完了・インセット反映後)にもう一度同じ処理を通す。avoider の amount 計算は
            // 「既に見えていれば 0」なので二重実行は no-op(冪等)— 一発目で足りていた場合の副作用なし。
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidShowNotification)) { note in
                guard fullscreenCoordinator.activeHost == nil else { return }
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
        //
        // 【監査 2026-07-18 LOW: fullscreenCoordinator.activeHost の強参照を画面破棄経路で断つ】
        // FullscreenCoordinator.activeHost は「今 fullscreen 昇格中のカード」への強参照(@Observable の
        // var)。newChat / 画面破棄で ChatBodyView 自体が捨てられても、activeHost が生きていれば
        // その InlineCardHost(webView/session を強参照で抱える大きなオブジェクト)は解放されない
        // (fullscreenCoordinator 自体は @State でこの View と寿命を共にするので通常は問題にならないが、
        // 反証検証で「retry 経路での混線」は成立しないと判明した一方、画面破棄そのものの経路は
        // 塞がれていなかった)。cardRegistry.teardownAll() と同じ場所で activeHost を明示的に nil にし、
        // 強参照を断つ。dismiss()(= restoreInline の順序復帰)は呼ばない —— 画面ごと消える以上、
        // カードを見た目上 inline に戻す意味は無く、teardownAll が直後に全 session を畳むので
        // restoreInline の host-context-changed 送信は無駄な往復になるだけ(最小修正)。
        .onDisappear {
            // 監査 2026-07-18 MEDIUM: 画面破棄で進行中の送信(LLM ストリーミング・MCP tools/call)を
            // 止める。newChat() 経路(ChatHomeViewModel.newChat 冒頭)とは別の破棄経路
            // (タブ切り替え・ナビゲーション pop 等、ChatBodyView 自体が画面から外れるケース)を
            // ここで塞ぐ。cancelActiveSend() は activeSendTask が無ければ no-op なので二重に
            // 呼んでも安全。
            chatVM.cancelActiveSend()
            cardRegistry.teardownAll()
            fullscreenCoordinator.activeHost = nil
        }
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
}

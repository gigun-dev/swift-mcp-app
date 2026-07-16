// ツール結果の ui:// カードをチャット内にインライン描画する層(T5・設計 §4/§5)。
//
// P2 のスパイク(TodosCardSpikeView)は「単カード全画面」だったが、T5 は「1ツール結果 = 1カード」を
// チャット文脈に一般化する。P2 で実証したフロー
//   proxy.fetchAppHTML → AppCardWebViewFactory.make → AppsBridgeSession(start → sendToolInput →
//   sendToolResult) → teardown、参照の強保持
// を「CardEmbed 1件を描画する」形に落とす。
//
// ---------------------------------------------------------------------------------------------
// 【最重要の設計判断: カードのライフサイクルと LazyVStack のスクロール問題】(設計 §4「カードの生存」)
//
// 設計 §4 は「チャットスクロールで画面外に出ても WKWebView は保持(再生成は高コスト・状態が飛ぶ)」を
// 要求する。ところが ChatBodyView のメッセージ列は LazyVStack で、行が画面外に出ると View が破棄され
// onDisappear が呼ばれる。もし InlineCardView 自体が session/webView を @State で持つと、スクロールで
// 破棄 → 再表示のたびに作り直し(fetchAppHTML から握手まで全部やり直し)になり、カード内で進めた
// 往復状態(complete したチェック等)が飛ぶ。これは §4 の生存方針に反する。
//
// 【採った解(タスク指示の「現実解」)】セッション群(webView + transport + coordinator + session)を
// **InlineCardView の外**、すなわちチャット画面が生きている限り生存する `InlineCardRegistry`
// (ChatBodyView が @State で1個所有)に **cardID キーで保持**する。InlineCardView は「registry から
// 同じ host を引いて、その webView を載せるだけ」にする。こうすると:
//  - スクロールで InlineCardView が破棄・再生成されても、registry の host は生き続けるので
//    buildIfNeeded は2回目以降 no-op(既存 webView をそのまま再表示)= 往復状態が飛ばない。
//  - AppCardView が「準備済み WKWebView を載せるだけ」の設計(AppCardView.swift 冒頭)とも整合する。
//
// 【teardown の方針】スクロールアウト(onDisappear)では teardown しない(§4 の生存優先)。teardown は
// チャット画面そのものが閉じるとき(ChatBodyView.onDisappear)に registry がまとめて行う。
//
// 【ライブ WKWebView の枚数上限(§4 の5枚→スナップショット降格)は T5 では未実装】スナップショット機構
// (outerHTML 取得・JS 無効ロード)は T6 で作るので、その転用である枚数上限も T6 送り(設計 §4 も
// 「スナップショット機構を作る以上、転用はほぼタダ」と T6 前提で書く)。ここでは上限を設けない。
// ---------------------------------------------------------------------------------------------
import SwiftUI
import UIKit     // UIScreen(fullscreen 推定寸法の算出・§5 H4)
import WebKit
import OSLog
import Kernel    // CardEmbed・JSONValue・UIDisplayMode・ContainerDimensions
import Services  // AppsServerProxy・AppsBridgeSession・WebViewTransport・AppCardWebCoordinator 等

/// 1枚のインラインカードの「構築物」を強参照で束ねて生存させるホスト(設計 §4 の生存単位)。
///
/// @MainActor @Observable: `webView`(構築完了で nil→非nil)を SwiftUI が観測し、プレースホルダ→カードへ
/// 差し替える。transport/coordinator/session は手放すとブリッジが停止する(delegate が weak・
/// TodosCardSpikeViewModel と同じ理由)ので、ここで強参照して生かし続ける。
@MainActor
@Observable
final class InlineCardHost: Identifiable {
    /// 準備済み WKWebView。構築完了で publish され、InlineCardView がこれを載せる。未構築は nil。
    private(set) var webView: WKWebView?

    /// 【fable #3 で見つかったバグの経緯】旧実装は build() の catch で logger.error するだけで
    /// この状態を持たず、View 側は「webView == nil ならローディング」の2値分岐だった。結果、
    /// HTML 取得失敗などで構築が catch に落ちても webView は永遠に nil のままなので、
    /// InlineCardView はスピナーを**無限に**回し続けていた(構築失敗なのにローディング表示・実質バグ)。
    /// この bool を @Observable の一員として追加し、View 側を3分岐(成功/失敗/構築中)にすることで
    /// 「ローディングとエラーの区別は基本作法」(fable ベスプラ調査 #3/#7)に合わせる。
    /// enum LoadState { loading, ready, failed } も検討したが、ready は webView != nil で兼ねられるので
    /// 別属性を増やさず bool 1個に留めた(webView と合わせて実質3状態になる)。
    private(set) var buildFailed: Bool = false

    /// displayMode の**単一の真実**(P4-DM・設計 04 §3 責務表・§5 H4-A)。@Observable なので、これを
    /// body で読む View(InlineCardView / FullscreenCardView)は変化で再評価され、AppCardView の
    /// 再アダプト(webView の inline↔sheet 載せ替え)が発火する。Session の currentDisplayMode は
    /// この値の「影(ワイヤ通知の相関用)」であって真実ではない。
    var displayMode: UIDisplayMode = .inline

    /// fullscreen 昇格の調停役(高々1枚・決定2b)。registry 経由で ChatBodyView 所有の
    /// FullscreenCoordinator が注入される。weak: coordinator は ChatBodyView(@State)が所有し、
    /// host はそれを参照するだけ(所有の輪を作らない)。名前が既存の AppCardWebCoordinator
    /// (下の private var coordinator)と衝突するので fullscreenCoordinator と明示する。
    private(set) weak var fullscreenCoordinator: FullscreenCoordinator?

    /// registry(host 生成時)から調停役を注入する。
    func attach(fullscreenCoordinator: FullscreenCoordinator) {
        self.fullscreenCoordinator = fullscreenCoordinator
    }

    /// `.sheet(item:)` 用の Identifiable 準拠。インスタンス同一性で識別する(host は registry で
    /// cardID キーに1つ、生存中は同一インスタンス)。
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    /// カード高さ(size-changed 追従・設計 §5)。ObservableObject なので View 側は @ObservedObject で観測。
    /// InlineCardHost(@Observable)とは別機構だが、AppCardState を新規に作り替えない方針(既存の
    /// AppCardView/スパイクと共有の高さ状態型)なのでそのまま流用する。
    let cardState = AppCardState()

    /// スナップショット(outerHTML)取得時に呼ばれるコールバック(T6・設計 §5)。
    /// InlineCardView が build 前に host へ差し込む(identity=(turnIndex,cardIndex) を閉じ込めた
    /// closure で、最終的に ChatViewModel.setCardSnapshot を叩く)。@MainActor: evaluateJavaScript の
    /// 完了ハンドラはメインスレッドで呼ばれ、setCardSnapshot も @MainActor なので整合する。
    var onSnapshot: (@MainActor (String) -> Void)?

    /// size-changed 到達を合図に一度スナップショットを取ったか(設計 §5「第一候補」)。
    /// teardown 時の取り直し(保険)は didCapture に関わらず毎回行う。
    private var didCaptureOnSizeChanged = false

    // 生存させ続ける参照群(手放すと停止する。TodosCardSpikeViewModel のプロパティ群と同じ役割)。
    private var transport: WebViewTransport?
    private var coordinator: AppCardWebCoordinator?
    private var session: AppsBridgeSession?
    private var buildTask: Task<Void, Never>?

    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "inlinecard")

    /// inline の実 maxHeight(可視高 × 0.65・P4-DM 決定1・設計 04 §5 H1)と実測幅。build 時に
    /// ChatBodyView から渡され、①Session の containerDimensions.maxHeight として広告、②onSizeChanged の
    /// クランプ上限、③inline 復帰時の host-context-changed の寸法、に使う。build 前(未確定)は 0。
    ///
    /// 【4000 番兵の廃止(設計 04 §1・決定1)】旧実装は maxHeight=4000 の「安全網」で実質無制限追従だった。
    /// これは「spec の maxHeight を実装していないことの代替」であり、H1 で可視高ベースの実制約へ置換した。
    /// 暴走(カードが異常な巨大高さを報告)への安全網は、maxHeight そのものがクランプ上限を兼ねるので別途持たない
    /// (実 maxHeight を超える報告は一律クランプされる)。
    private var inlineMaxHeight: CGFloat = 0
    private var containerWidth: CGFloat = 0

    /// カードを1度だけ構築する。2回目以降(スクロール往復での再 .task)は no-op(既存 webView を維持)。
    /// - Parameters:
    ///   - proxy: 接続共有の AppsServerProxy(fetchAppHTML と tools/call 素通しの両方を担う・設計 §4)。
    ///   - card: 描画対象の CardEmbed(resourceUri・arguments・structuredContent を使う)。
    ///   - containerWidth: カード列の実測幅(設計 §5「幅=カード列の実測幅」)。initialize の
    ///     containerDimensions.width としてカードへ渡り、caldav カードがこの幅にレイアウトする。
    ///   - maxHeight: inline の実 maxHeight(可視高 × 0.65・H1)。containerDimensions.maxHeight として
    ///     広告され、size-changed のクランプ上限を兼ねる。
    func buildIfNeeded(proxy: AppsServerProxy, card: CardEmbed, containerWidth: CGFloat, maxHeight: CGFloat) {
        guard buildTask == nil else { return }  // 既に構築開始済み(= host は生存中)なら何もしない。
        // 寸法を保持(onSizeChanged クランプ・inline 復帰通知で使う)。build は非同期なのでここで確定させる。
        self.containerWidth = containerWidth
        self.inlineMaxHeight = maxHeight
        buildTask = Task { await self.build(proxy: proxy, card: card, containerWidth: containerWidth, maxHeight: maxHeight) }
    }

    private func build(proxy: AppsServerProxy, card: CardEmbed, containerWidth: CGFloat, maxHeight: CGFloat) async {
        do {
            // 1. HTML プリフェッチ(接続内キャッシュが効くので2枚目以降の同一 URI は resources/read を省く)。
            let (html, _) = try await proxy.fetchAppHTML(uri: card.resourceUri)

            // 2. サンドボックス WKWebView 生成。**インラインは高さ追従なので scrollEnabled:false**
            //    (設計 §5・AppCardWebViewFactory の scrollEnabled 引数コメント)。内部スクロールを切り、
            //    size-changed が返す max-content 高さを .frame(height:) で追従させる。
            let transport = WebViewTransport()
            self.transport = transport
            let coordinator = AppCardWebCoordinator()
            self.coordinator = coordinator
            let webView = await AppCardWebViewFactory.make(
                transport: transport, html: html, coordinator: coordinator, scrollEnabled: false)

            // 3. セッション起動。onSizeChanged は高さを cardState へ流し込み、実 maxHeight(可視高×0.65・H1)で
            //    クランプしてチャットを食い潰さない(設計 04 §5 H1)。
            let cardState = self.cardState
            let session = AppsBridgeSession(
                transport: transport,
                proxy: proxy,
                containerWidth: Double(containerWidth),
                maxHeight: Double(maxHeight),
                onSizeChanged: { [weak self] height in
                    await MainActor.run {
                        guard let self else { return }
                        // 【fullscreen 中は .frame 追従を停止(P4-DM 決定2・設計 04 §5 H4-E)】sheet 中は
                        // カードが overflow-y:auto で自己スクロールし、器(sheet)の寸法は固定なので、
                        // size-changed の高さは inline の枠に反映しない(反映すると sheet を閉じた瞬間に
                        // 巨大高さが残る)。inline 復帰後の次の size-changed で最新値が入る。
                        guard self.displayMode == .inline else {
                            self.captureSnapshotOnFirstSizeChanged()
                            return
                        }
                        // 【inline は実 maxHeight でクランプ(H1・設計 04 決定1)】旧実装は 4000 番兵で
                        // 実質無制限追従だったが、可視高×0.65 の実制約に置換した。maxHeight 内に収まる
                        // (少数件)ならカードは内容ぴったりで全部見え、超える場合はここでクランプされる
                        // (超過分はカード側が畳み UI = caldav C2/C3 で自己整形する。caldav 未デプロイ時は
                        // クランプで内容が見切れるが、これは設計どおりの既知の中間状態)。
                        withAnimation(.easeOut(duration: 0.3)) {
                            cardState.desiredHeight = min(CGFloat(height), self.inlineMaxHeight)
                        }
                        // スナップショット取得の第一候補(設計 §5): tool-result 配送後、カードが
                        // 描画確定した合図として size-changed が到達した時点で outerHTML を取る。
                        // 初回到達で1度だけ(以降の size-changed は同じ DOM の再計測が主で、
                        // 取り直しは teardown 時にまとめて行う——毎 size-changed で JS 評価すると
                        // スクロール中に無駄な評価が積み上がるため)。
                        self.captureSnapshotOnFirstSizeChanged()
                    }
                },
                // fullscreen 昇格の受理判断(P4-DM・設計 04 §5 H4-D)。カード発 request-display-mode を
                // 受けて、調停役(coordinator)に「今 fullscreen を出せるか(高々1枚・決定2b)」を問う。
                // このハンドラを注入すること自体が「fullscreen を広告する」意味を持つ(H4-F)。
                onDisplayModeRequested: { [weak self] requested in
                    // @Sendable クロージャ。MainActor 隔離の host/coordinator を触るので hop する。
                    await MainActor.run {
                        // fullscreen 以外(pip 等)は当面非対応 → 現状維持(inline)。
                        guard requested == .fullscreen else {
                            return DisplayModeResolution(mode: .inline)
                        }
                        guard let self, let coordinator = self.fullscreenCoordinator else {
                            return DisplayModeResolution(mode: .inline)  // 調停役未接続なら安全に拒否。
                        }
                        // 推定寸法(large detent ≒ 可視高 − トップインセット・§5 H4-D)。sheet 実寸は提示
                        // 完了まで確定しないので、まずこの推定を返す(必要なら提示後に補正・§5 H4-E)。
                        let dims = self.estimatedFullscreenDimensions()
                        return coordinator.requestFullscreen(self, estimatedDimensions: dims)
                    }
                })
            self.session = session
            await session.start()

            // 4. webView を publish(この時点で View は WKWebView をマウントし、カードは ui/initialize を
            //    送ってくる)。start() の後に publish する順序は TodosCardSpikeViewModel と同じ
            //    (握手はマウント後・以降の配送は initialized まで outbox に退避される・設計 §2)。
            self.webView = webView

            // 5. tool-input(引数)→ tool-result(結果)の順で配送。ready 前は outbox に退避され、
            //    initialized 受信で FIFO flush される(設計 §2・スパイクと同順)。
            await session.sendToolInput(arguments: card.arguments ?? .object([:]))
            await session.sendToolResult(card.structuredContent ?? .null)
            logger.notice("インラインカード構築完了 uri=\(card.resourceUri, privacy: .public)")
        } catch {
            // 構築失敗(HTML 取得失敗・mimeType 不一致など)。webView は nil のままだが、buildFailed を
            // 立てることで View 側がローディングとエラーを区別できるようにする(fable #3・上のコメント参照)。
            // チャット全体は壊さない(1カードの失敗に閉じる)。
            // 【リトライは今回スコープ外】もし将来 retry ボタンを足すなら、buildTask を nil に戻して
            // buildFailed も false に戻す必要がある(buildIfNeeded の guard buildTask == nil に依存するため)。
            logger.error("インラインカード構築失敗 uri=\(card.resourceUri, privacy: .public): \(String(reflecting: error), privacy: .public)")
            self.buildFailed = true
        }
    }

    /// 明示破棄(チャット画面が閉じるとき registry から呼ばれる)。teardown を投げてから参照を手放す。
    func teardown() {
        // 保険のスナップショット取り直し(設計 §5「保険としてターン確定時にも取り直す」)。
        // カード離脱/画面クローズ時点の最終状態(size-changed 後に往復で内容が変わった等)を
        // 取りこぼさないため、didCapture に関わらず最後に1度取る。webView 破棄前に評価する。
        captureSnapshot()
        let session = self.session
        Task { await session?.teardown() }
    }

    // MARK: - fullscreen(sheet)器の連携(P4-DM・設計 04 §5 H4)

    /// fullscreen 昇格時にカードへ渡す推定寸法(§5 H4-D)。sheet の large detent は
    /// 「画面高 − トップの安全余白」に近い。sheet 実寸は提示アニメーション完了まで確定しないため、
    /// まず画面 bounds からの推定を返し、必要なら提示後に補正する(§5 H4-E・高さ誤差の実害は小さい)。
    /// 幅は画面幅(sheet は全幅)。
    func estimatedFullscreenDimensions() -> ContainerDimensions {
        let screen = UIScreen.main.bounds.size
        // トップインセット + グラバー余白の概算(large detent は上端を少し残す)。実測不要な概算値。
        let topReserve: CGFloat = 60
        return ContainerDimensions(
            width: Double(screen.width),
            maxHeight: Double(max(0, screen.height - topReserve)))
    }

    /// webView 内部スクロールの動的切替(§5 H4・§6-2)。fullscreen ではカード自己スクロールを許し、
    /// inline では切る(チャット全体スクロールと二重にしない)。生成時引数でなく実行時に切替できる。
    func setWebViewScrollEnabled(_ enabled: Bool) {
        webView?.scrollView.isScrollEnabled = enabled
    }

    /// sheet dismiss で inline へ戻す一連の処理(P4-DM・設計 04 §5 H4-E の**固定順序**)。
    /// 順序は「rehome → scrollEnabled=false → host-context-changed(inline)」で固定する
    /// (寸法通知が rehome より先だとカードが旧寸法でレイアウトするため)。
    func restoreInline() {
        // 1. rehome: displayMode=.inline に戻すと、inline 側 AppCardView が再アダプトで webView を取り戻す
        //    (@Observable 観測で InlineCardView が再評価される。設計 04 §6-7 の rehomeToken 保険は
        //    この観測が効くので不要 —— スパイクの View 側 @State bump を @Observable の単一真実が代替する)。
        displayMode = .inline
        // 2. scrollEnabled=false: inline は高さ追従で内部スクロール不要(チャット全体でスクロールする)。
        setWebViewScrollEnabled(false)
        // 3. host-context-changed(inline + inline 寸法): カードに inline へ戻ったことと寸法を通知。
        let dims = ContainerDimensions(width: Double(containerWidth), maxHeight: Double(inlineMaxHeight))
        let session = self.session
        Task { await session?.notifyDisplayModeChanged(to: .inline, containerDimensions: dims) }
    }

    // MARK: - スナップショット取得(設計 §5)

    /// size-changed 初回到達時に1度だけ outerHTML を取る(第一候補のタイミング)。
    private func captureSnapshotOnFirstSizeChanged() {
        guard !didCaptureOnSizeChanged else { return }
        didCaptureOnSizeChanged = true
        captureSnapshot()
    }

    /// 現在の webView の DOM を `document.documentElement.outerHTML` でシリアライズし、
    /// onSnapshot へ渡す(設計 §5)。webView 未構築や onSnapshot 未設定なら何もしない。
    /// 【outerHTML の限界(設計 §5 記載)】input の入力途中値・canvas は落ちるが、caldav の
    /// todos/agenda はリスト表示なので実害なし。再訪側は allowsContentJavaScript=false でロードする。
    private func captureSnapshot() {
        guard let webView, let onSnapshot else { return }
        webView.evaluateJavaScript("document.documentElement.outerHTML") { result, error in
            // 完了ハンドラはメインスレッド。MainActor 隔離をコンパイラに伝えるため Task で包む
            // (evaluateJavaScript の completion は @Sendable 非分離クロージャなので、
            //  @MainActor の onSnapshot を直接は呼べない)。
            if let html = result as? String {
                Task { @MainActor in onSnapshot(html) }
            } else if let error {
                self.logger.error("outerHTML 取得に失敗: \(String(reflecting: error), privacy: .public)")
            }
        }
    }
}

/// cardID → InlineCardHost の台帳。ChatBodyView が @State で1個所有し、チャット画面の生存期間中
/// カード群を生かし続ける(上のファイル冒頭「最重要の設計判断」参照)。@Observable にしないのは、
/// この dict 自体の変化を View が観測する必要がないため(観測対象は各 host.webView・そちらが @Observable)。
@MainActor
final class InlineCardRegistry {
    private var hosts: [String: InlineCardHost] = [:]

    /// key に対応する host を返す(無ければ生成して登録)。get-or-create なので body から呼んでも
    /// 同一インスタンスが返り、スクロール再生成に耐える。
    /// - Parameter coordinator: fullscreen 昇格の調停役(ChatBodyView 所有)。生成時に host へ注入する
    ///   (registry 経由が自然・設計 04 §5 H4-D)。既存 host には再注入しない(生存中は同一 coordinator)。
    func host(for key: String, coordinator: FullscreenCoordinator) -> InlineCardHost {
        if let existing = hosts[key] { return existing }
        let host = InlineCardHost()
        host.attach(fullscreenCoordinator: coordinator)
        hosts[key] = host
        return host
    }

    /// 全カードを破棄(チャット画面クローズ時)。以降の再表示は無いので session を畳んでよい。
    func teardownAll() {
        for host in hosts.values { host.teardown() }
        hosts.removeAll()
    }
}

/// 1枚のインラインカードを描画する View。実体(webView/session)は host が持ち、この View は
/// 「host の準備済み webView を高さ追従で載せるだけ」(AppCardView と同じ薄さ)。
struct InlineCardView: View {
    let host: InlineCardHost
    let proxy: AppsServerProxy
    let card: CardEmbed
    let containerWidth: CGFloat
    /// inline の実 maxHeight(可視高 × 0.65・P4-DM 決定1・設計 04 §5 H1)。ChatBodyView が可視高から算出して渡す。
    let maxHeight: CGFloat
    /// スナップショット取得時に呼ばれる(T6・設計 §5)。ChatBodyView が identity=(turnIndex,cardIndex)
    /// を閉じ込めて渡し、最終的に ChatViewModel.setCardSnapshot を叩く。既定 nil で T5 の既存呼び出し
    /// (スナップショット不要のプレビュー等)を壊さない。
    var onSnapshot: (@MainActor (String) -> Void)?

    // 高さ(desiredHeight)は AppCardState(ObservableObject)で観測する。@Observable の host とは
    // 別機構だが、既存の高さ状態型を作り替えない方針(ファイル冒頭 InlineCardHost.cardState 参照)。
    @ObservedObject private var cardState: AppCardState

    init(
        host: InlineCardHost,
        proxy: AppsServerProxy,
        card: CardEmbed,
        containerWidth: CGFloat,
        maxHeight: CGFloat,
        onSnapshot: (@MainActor (String) -> Void)? = nil
    ) {
        self.host = host
        self.proxy = proxy
        self.card = card
        self.containerWidth = containerWidth
        self.maxHeight = maxHeight
        self.onSnapshot = onSnapshot
        // @ObservedObject を host の cardState に束ねる(init で _cardState を組む標準パターン)。
        self._cardState = ObservedObject(wrappedValue: host.cardState)
    }

    var body: some View {
        content
            // 構築は host に一任(2回目以降 no-op)。containerWidth が未確定(初期 0)の間は構築を保留し、
            // 実測幅が来てから1度だけ構築する(狭すぎる幅でカードがレイアウトされるのを避ける)。
            .task(id: containerWidth > 0) {
                guard containerWidth > 0 else { return }
                // スナップショット取得口を host に差し込んでから構築する(build 中の size-changed で
                // 取得が走るので、それより前に設定しておく)。host は生存し続けるが closure は
                // View 再生成のたびに新しくなりうるので、毎回入れ替える(identity は同じなので実害なし)。
                host.onSnapshot = onSnapshot
                host.buildIfNeeded(proxy: proxy, card: card, containerWidth: containerWidth, maxHeight: maxHeight)
            }
        // onDisappear では teardown しない(設計 §4 の生存優先・ファイル冒頭の判断)。スクロールアウトは
        // 一時的な View 破棄にすぎず、host は registry が生かし続ける。teardown はチャット画面クローズ時に
        // ChatBodyView が registry.teardownAll() でまとめて行う。
    }

    @ViewBuilder
    private var content: some View {
        // host.webView(@Observable)を読むことで、構築完了(nil→非nil)時に自動で差し替わる。
        if let webView = host.webView {
            // role:.inline + host.displayMode を渡す(P4-DM・container 再アダプト方式)。host.displayMode を
            // ここで読むことで @Observable 依存が張られ、fullscreen 昇格/復帰で content が再評価され、
            // AppCardView の updateUIView が走って webView の載せ替え(奪い合いガード込み)が起きる。
            // fullscreen 中はこの inline 側 AppCardView は webView を所有しない(sheet 側が持つ)ため
            // 空の枠が cardState.desiredHeight で残る(カードは sheet に居る・設計 04 §6)。
            AppCardView(webView: webView, role: .inline, activeDisplayMode: host.displayMode)
                .frame(height: cardState.desiredHeight)  // size-changed 追従(設計 §5・fullscreen 中は停止)。
                .frame(maxWidth: .infinity)
                .background(Color(white: 0.98))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                // 角丸+枠(TodosCardSpike の見た目を踏襲)。
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.85)))
        } else if host.buildFailed {
            // 【fable #3: 構築失敗のエラー表示】旧実装はこの分岐が無く、失敗時も下のローディングに
            // 落ちてスピナーが回り続けていた(ファイル冒頭 buildFailed 宣言のコメント参照)。
            // プレースホルダと同じ角丸+枠のトーンを踏襲しつつ、エラーだと分かる見た目(warning 色の
            // 三角アイコン+文言+ツール名)にする。リトライは今回のスコープ外(上の build() コメント参照)。
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.96))
                .frame(height: 120)
                .overlay(
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title3)
                            .foregroundStyle(.orange)
                        Text("カードを読み込めませんでした")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text(card.toolName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                )
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.85)))
                // #8 随伴: エラーの意味をまとめて1つのアクセシビリティ要素として読み上げる。
                .accessibilityElement(children: .combine)
                .accessibilityLabel("カードを読み込めませんでした: \(card.toolName)")
        } else {
            // 【fable #7: ローディング改善】旧実装は無地の ProgressView(無名スピナー)だけで、
            // 何を読み込んでいるか分からなかった。ツール名ラベル + skeleton 風の薄いバー2本を添える
            // ことで「何を待っているか」を示す(caldav カード側の skeleton に寄せる必要はなく、
            // ホスト側は素朴な表現で良い・タスク指示)。HTML 取得〜握手までの数百 ms の間だけ見える。
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: 0.96))
                .frame(height: 120)
                .overlay(
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("\(card.toolName) を読み込み中…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // skeleton 風の薄いバー(内容が来る前の骨格を示唆する程度。派手にしない)。
                        VStack(spacing: 4) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(white: 0.88))
                                .frame(width: 120, height: 6)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(white: 0.88))
                                .frame(width: 80, height: 6)
                        }
                    }
                )
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color(white: 0.85)))
                .accessibilityLabel("\(card.toolName) を読み込み中")
        }
    }
}

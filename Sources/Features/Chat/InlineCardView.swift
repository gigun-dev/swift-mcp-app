// ツール結果の ui:// カードをチャット内にインライン描画する層(T5・設計 §4/§5)。
//
// P2 のスパイク(TodosCardSpikeView)は「単カード全画面」だったが、T5 は「1ツール結果 = 1カード」を
// チャット文脈に一般化する。P2 で実証したフロー
//   proxy.fetchAppHTML → AppCardWebViewFactory.make → AppsBridgeSession(start → sendToolInput →
//   sendToolResult) → teardown、参照の強保持
// を「CardEmbed 1件を描画する」形に落とす。
//
// 【最重要の設計判断: カードのライフサイクルと LazyVStack のスクロール問題】(設計 §4「カードの生存」)
// 設計 §4 は「チャットスクロールで画面外に出ても WKWebView は保持(再生成は高コスト・状態が飛ぶ)」を
// 要求する。ところが ChatBodyView のメッセージ列は LazyVStack で、行が画面外に出ると View が破棄され
// onDisappear が呼ばれる。もし InlineCardView 自体が session/webView を @State で持つと、スクロールで
// 破棄 → 再表示のたびに作り直し(fetchAppHTML から握手まで全部やり直し)になり、カード内で進めた
// 往復状態(complete したチェック等)が飛ぶ。これは §4 の生存方針に反する。
// 【採った解(タスク指示の「現実解」)】セッション群(webView + transport + coordinator + session)を
// **InlineCardView の外**、すなわちチャット画面が生きている限り生存する `InlineCardRegistry`
// (ChatBodyView が @State で1個所有)に **cardID キーで保持**する。InlineCardView は「registry から
// 同じ host を引いて、その webView を載せるだけ」にする。こうすると:
//  - スクロールで InlineCardView が破棄・再生成されても、registry の host は生き続けるので
//    buildIfNeeded は2回目以降 no-op(既存 webView をそのまま再表示)= 往復状態が飛ばない。
//  - AppCardView が「準備済み WKWebView を載せるだけ」の設計(AppCardView.swift 冒頭)とも整合する。
// 【teardown の方針】スクロールアウト(onDisappear)では teardown しない(§4 の生存優先)。teardown は
// チャット画面そのものが閉じるとき(ChatBodyView.onDisappear)に registry がまとめて行う。
//
// 【ライブ WKWebView の枚数上限(§4 の5枚→スナップショット降格)は T5 では未実装】スナップショット機構
// (outerHTML 取得・JS 無効ロード)は T6 で作るので、その転用である枚数上限も T6 送り(設計 §4 も
// 「スナップショット機構を作る以上、転用はほぼタダ」と T6 前提で書く)。ここでは上限を設けない。
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

    /// カードが fullscreen 昇格に対応するか(UX #1・fable #1)。Session が initialize で受け取った
    /// appCapabilities.availableDisplayModes に "fullscreen" があれば true。@Observable なので、
    /// これを読む InlineCardView は変化で再評価され、⤢ オーバーレイの出し分けが発火する。
    /// 【なぜこれで出し分けるか(apps.mdx:786)】ホスト発の fullscreen 切替はカードが宣言したモードにしか
    /// できない。宣言していないカードに ⤢ を出すと押しても違反になる(死にボタン)ので、宣言時だけ出す。
    /// 初期値 false = 未 initialize / 非対応カードでは ⤢ を出さない(安全側)。
    private(set) var cardSupportsFullscreen: Bool = false

    /// カード(リソース)が「ホストの枠・背景を付けてほしいか」の宣言(#6 prefersBorder・
    /// spec.types.ts:590 McpUiResourceMeta.prefersBorder / apps.mdx:222-229)。resources/read 結果の
    /// content-level `_meta.ui.prefersBorder` を build 時に読んで反映する。@Observable なので、
    /// これを読む InlineCardView は変化で再評価され、枠/背景の出し分けが発火する。
    ///
    /// 三値(spec 準拠):
    ///   - true  → ホストが枠+背景を描く(現行の見た目)
    ///   - false → 枠+背景なしの素のカード
    ///   - nil(未指定・初期値)→ **ホストが決める**。本ホストの既定は「枠+背景あり」= 現行の見た目に倒す
    ///     (spec は既定を定めず「ホスト依存・明示推奨」とだけ言う。既定を現行維持にして退行ゼロにする)。
    private(set) var prefersBorder: Bool?

    /// fullscreen 昇格の調停役(高々1枚・決定2b)。registry 経由で ChatBodyView 所有の
    /// FullscreenCoordinator が注入される。weak: coordinator は ChatBodyView(@State)が所有し、
    /// host はそれを参照するだけ(所有の輪を作らない)。名前が既存の AppCardWebCoordinator
    /// (下の private var coordinator)と衝突するので fullscreenCoordinator と明示する。
    private(set) weak var fullscreenCoordinator: FullscreenCoordinator?

    /// registry(host 生成時)から調停役を注入する。
    func attach(fullscreenCoordinator: FullscreenCoordinator) {
        self.fullscreenCoordinator = fullscreenCoordinator
    }

    /// カード発 tools/call(=カード内のユーザー操作: done/undo・追加・削除等)の触覚フィードバック
    /// (ユーザー要望 2026-07-17)。ChatBodyView が haptics コントローラの closure を差し込む。
    /// カード内タップ自体はホストから不可視だが、操作は必ず bridge の tools/call 素通しを通るので、
    /// Session の onCardToolCall フック経由で任意の MCP アプリに中立に効く(ビジョン2)。nil = 無効。
    var onCardToolCall: (() -> Void)?

    /// `.sheet(item:)` 用の Identifiable 準拠。インスタンス同一性で識別する(host は registry で
    /// cardID キーに1つ、生存中は同一インスタンス)。
    nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) }

    /// カード高さ(size-changed 追従・設計 §5)。ObservableObject なので View 側は @ObservedObject で観測。
    /// InlineCardHost(@Observable)とは別機構だが、AppCardState を新規に作り替えない方針(既存の
    /// AppCardView/スパイクと共有の高さ状態型)なのでそのまま流用する。
    let cardState = AppCardState()

    /// outerHTML の取得時機・重複防止は専用 collaborator に閉じる。
    var onSnapshot: (@MainActor (String) -> Void)?
    private let snapshotter = InlineCardSnapshotter()

    // 生存させ続ける参照群(手放すと停止する。TodosCardSpikeViewModel のプロパティ群と同じ役割)。
    private var transport: WebViewTransport?
    private var coordinator: AppCardWebCoordinator?
    var session: AppsBridgeSession?
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

    // 現在のホスト外観(#5)。build 時に InlineCardView から渡された colorScheme を保持し、
    // ①initialize の theme/styles、②webView.overrideUserInterfaceStyle、③外観変更時の差分検出に使う。
    // 初期 nil = build 前(未確定)。updateColorScheme が build 後の変更で更新する。
    private var currentColorScheme: ColorScheme?

    // fullscreen 昇格/inline 復帰の host-context-changed を「実際の reparent 完了後」まで遅延させる
    // ための保留箱(監査 2026-07-18 HIGH #1)。requestFullscreenFromHost / restoreInline /
    // Session.onDisplayModeRequested ハンドラは、寸法を直接送らずここへ積むだけにする。
    // AppCardView.onAdopted(実際に webView が新コンテナへ載った瞬間)から notifyReparented() が
    // 呼ばれ、ここに積まれていればそこで初めて session.notifyDisplayModeChanged を送る。
    // nil のとき notifyReparented は何もしない(通常の再描画による adopt 呼び出しを無視する)。
    var pendingDisplayModeNotification: (mode: UIDisplayMode, dims: ContainerDimensions)?

    // カード発 request の応答を実 reparent まで待たせる一度きりゲート。詳細な原因・timeout 方針は
    // FullscreenPresentationGate.swift に閉じ、肥大しやすい InlineCardHost は連携だけを持つ。
    let fullscreenPresentationGate = FullscreenPresentationGate()

    /// カードを1度だけ構築する。2回目以降(スクロール往復での再 .task)は no-op(既存 webView を維持)。
    /// - Parameters:
    ///   - proxy: 接続共有の AppsServerProxy(fetchAppHTML と tools/call 素通しの両方を担う・設計 §4)。
    ///   - card: 描画対象の CardEmbed(resourceUri・arguments・structuredContent を使う)。
    ///   - containerWidth: カード列の実測幅(設計 §5「幅=カード列の実測幅」)。initialize の
    ///     containerDimensions.width としてカードへ渡り、caldav カードがこの幅にレイアウトする。
    ///   - maxHeight: inline の実 maxHeight(可視高 × 0.65・H1)。containerDimensions.maxHeight として
    ///     広告され、size-changed のクランプ上限を兼ねる。
    func buildIfNeeded(
        proxy: AppsServerProxy,
        card: CardEmbed,
        containerWidth: CGFloat,
        maxHeight: CGFloat,
        colorScheme: ColorScheme
    ) {
        guard buildTask == nil else { return }  // 既に構築開始済み(= host は生存中)なら何もしない。
        // 寸法を保持(onSizeChanged クランプ・inline 復帰通知で使う)。build は非同期なのでここで確定させる。
        self.containerWidth = containerWidth
        self.inlineMaxHeight = maxHeight
        self.currentColorScheme = colorScheme  // #5: initialize の theme/styles に載せる初期外観。
        buildTask = Task { await self.build(
            proxy: proxy,
            card: card,
            containerWidth: containerWidth,
            maxHeight: maxHeight,
            colorScheme: colorScheme
        ) }
    }

    private func build(
        proxy: AppsServerProxy,
        card: CardEmbed,
        containerWidth: CGFloat,
        maxHeight: CGFloat,
        colorScheme: ColorScheme
    ) async {
        do {
            // 1. HTML プリフェッチ(接続内キャッシュが効くので2枚目以降の同一 URI は resources/read を省く)。
            //    uiMeta = content-level の _meta.ui(#6: prefersBorder はここに載る・AppsServerProxy.fetchAppHTML)。
            let (html, uiMeta) = try await proxy.fetchAppHTML(uri: card.resourceUri)
            // #6: カードの枠・背景の希望を反映(spec.types.ts:590 / apps.mdx:222-229)。欠落・型違いは nil
            // (= ホスト既定「枠+背景あり」)に倒れ、現行の見た目を維持する。@Observable なので View が再評価される。
            self.prefersBorder = uiMeta?["prefersBorder"]?.boolValue

            // 2. サンドボックス WKWebView 生成。**インラインは高さ追従なので scrollEnabled:false**
            //    (設計 §5・AppCardWebViewFactory の scrollEnabled 引数コメント)。内部スクロールを切り、
            //    size-changed が返す max-content 高さを .frame(height:) で追従させる。
            let transport = WebViewTransport()
            self.transport = transport
            let coordinator = AppCardWebCoordinator()
            self.coordinator = coordinator
            let webView = await AppCardWebViewFactory.make(
                transport: transport, html: html, coordinator: coordinator, scrollEnabled: false
            )
            // #5: WKWebView 自体の外観をホストに合わせる。カード CSS が prefers-color-scheme を見る場合、
            // overrideUserInterfaceStyle を明示すると環境ではなくこの値でメディアクエリが解決される
            // (styles トークンを見ないカードでも、素の prefers-color-scheme だけでダーク化できる)。
            webView.overrideUserInterfaceStyle = colorScheme == .dark ? .dark : .light

            // 3. セッション起動。イベントごとの判断は専用メソッドへ分け、構築手順を直線に保つ。
            let session = AppsBridgeSession(
                transport: transport,
                proxy: proxy,
                containerWidth: Double(containerWidth),
                maxHeight: Double(maxHeight),
                theme: HostThemeBuilder.theme(for: colorScheme),
                styles: HostThemeBuilder.styles(for: colorScheme),
                onSizeChanged: { [weak self] height in
                    await self?.handleSizeChange(height, webView: webView)
                },
                onDisplayModeRequested: { [weak self] requested in
                    await self?.resolveDisplayMode(requested) ?? DisplayModeResolution(mode: .inline)
                },
                // 【Swift 6 captured-var 対応(2026-07-23)】外側の [weak self] で束ねた optional self を
                // 内側 MainActor.run クロージャがそのまま参照すると「concurrently-executing code での
                // captured var 'self' 参照」になる(Swift 6 ではエラー)。内側にも独立した [weak self]
                // キャプチャを付け、外側の var を跨がず内側クロージャ自身が weak 参照を持つ形にして解消する。
                onCardCapabilities: { [weak self] supports in
                    await MainActor.run { [weak self] in self?.cardSupportsFullscreen = supports }
                },
                onCardToolCall: { [weak self] in
                    await MainActor.run { [weak self] in self?.onCardToolCall?() }
                },
                // Self.openLink 直渡しは「非 Sendable 関数値→@Sendable クロージャ変換」で data race 警告が
                // 出る。何もキャプチャしないクロージャで包むと @Sendable 推論が効く(static 呼び出しは安全)。
                onOpenLink: { await Self.openLink($0) }
            )
            self.session = session
            await session.start()

            // 4. webView を publish(この時点で View は WKWebView をマウントし、カードは ui/initialize を
            //    送ってくる)。start() の後に publish する順序は TodosCardSpikeViewModel と同じ
            //    (握手はマウント後・以降の配送は initialized まで outbox に退避される・設計 §2)。
            self.webView = webView

            // 5. tool-input(引数)→ tool-result(結果)の順で配送。ready 前は outbox に退避され、
            //    initialized 受信で FIFO flush される(設計 §2・スパイクと同順)。
            await sendInitialPayload(card: card, session: session)
            logger.notice("インラインカード構築完了 uri=\(card.resourceUri, privacy: .public)")
        } catch {
            // 構築失敗(HTML 取得失敗・mimeType 不一致など)。webView は nil のままだが、buildFailed を
            // 立てることで View 側がローディングとエラーを区別できるようにする(fable #3・上のコメント参照)。
            // チャット全体は壊さない(1カードの失敗に閉じる)。
            // 【リトライは今回スコープ外】もし将来 retry ボタンを足すなら、buildTask を nil に戻して
            // buildFailed も false に戻す必要がある(buildIfNeeded の guard buildTask == nil に依存するため)。
            logger
                .error(
                    "インラインカード構築失敗 uri=\(card.resourceUri, privacy: .public): \(String(reflecting: error), privacy: .public)"
                )
            self.buildFailed = true
        }
    }

    /// tool-input(引数)→ tool-result(structuredContent)の順で初期ペイロードを配送する。
    ///
    /// 【履歴 revalidation gate 撤去後の姿(2026-07-23・queue 2)】
    /// 以前はここに「履歴由来なら _meta へ hint を載せて gate を arm し、成功完了までカードを触らせない」
    /// 経路があった。その gate/hint 機構は caldav 側裁定で撤去した(caldavリポジトリ docs/modeling/15・SWR):
    /// ホスト固有の `_meta` hint はサードパーティカードを全滅させ・RFC 5861(stale-while-revalidate)に
    /// 逆行し・ext-apps に足場が無い。鮮度は caldav 側 SWR(structuredContent 内 generatedAt の 60 秒判定)が
    /// 担い、その発火条件は「host が履歴復元時に保存済み toolResult をカードへ再 push すること」だけ。
    /// よってライブ・履歴を問わず、保存済み structuredContent を素直に tool-result として送る
    /// (この再 push こそが SWR の発火条件なので必ず残す・下の履歴経路テストで固定)。
    func sendInitialPayload(card: CardEmbed, session: AppsBridgeSession) async {
        await session.sendToolInput(arguments: card.arguments ?? .object([:]))
        await session.sendToolResult(card.structuredContent ?? .null)
    }

    /// inline は実 maxHeight でクランプし、fullscreen 中は高さ追従を止める。
    /// 初回 size-changed は描画確定の合図でもあるため、どちらの mode でも snapshot を取る。
    private func handleSizeChange(_ height: Double, webView: WKWebView) {
        if displayMode == .inline {
            withAnimation(.easeOut(duration: 0.3)) {
                cardState.desiredHeight = min(CGFloat(height), inlineMaxHeight)
            }
        }
        snapshotter.captureFirst(from: webView, receiver: onSnapshot)
    }

    /// URL 検証は Session 済み。UIKit の completion を async の成否へ橋渡しする。
    private static func openLink(_ url: URL) async -> Bool {
        await withCheckedContinuation { continuation in
            UIApplication.shared.open(url, options: [:]) { success in
                continuation.resume(returning: success)
            }
        }
    }

    /// 明示破棄(チャット画面が閉じるとき registry から呼ばれる)。teardown を投げてから参照を手放す。
    func teardown() {
        // 保険のスナップショット取り直し(設計 §5「保険としてターン確定時にも取り直す」)。
        // カード離脱/画面クローズ時点の最終状態(size-changed 後に往復で内容が変わった等)を
        // 取りこぼさないため、didCapture に関わらず最後に1度取る。webView 破棄前に評価する。
        snapshotter.capture(from: webView, receiver: onSnapshot)
        let session = self.session
        // fullscreen 提示中に画面自体が破棄された場合も、待機中の JSON-RPC callback を残さない。
        fullscreenPresentationGate.cancel()
        Task { await session?.teardown() }
    }

    // MARK: - fullscreen(sheet)器の連携(P4-DM・設計 04 §5 H4)

    /// ホスト UI(⤢ ボタン)発の fullscreen 昇格(UX #1・fable #1)。カード発 request-display-mode と
    /// **入口が違うだけで出口は同じ**: 調停役(coordinator)に受理を問い(高々1枚・決定2b)、受理されたら
    /// host-context-changed(fullscreen)をカードへ通知する。カード発は Session.onDisplayModeRequested 経由、
    /// ホスト発はこのメソッド経由。dismiss(inline 復帰)は既存の restoreInline / coordinator.dismiss が
    /// そのまま効く(出口が同じなので後始末も共通)。
    func requestFullscreenFromHost() {
        guard let coordinator = fullscreenCoordinator else { return }
        let dims = estimatedFullscreenDimensions()
        // requestFullscreen は host.displayMode=.fullscreen への更新も行う(占有中は .inline を返し何もしない)。
        let resolution = coordinator.requestFullscreen(self, estimatedDimensions: dims)
        guard resolution.mode == .fullscreen else { return }  // 別カードが占有中なら昇格しない。
        // 【監査 2026-07-18 HIGH #1】host-context-changed をここで直接送らない(カード発経路の
        // onDisplayModeRequested ハンドラと同じ理由・そちらのコメント参照)。保留箱に積み、
        // FullscreenCardView 側の実際の reparent 完了(AppCardView.onAdopted)を待つ
        // ——ホスト発とカード発を同じ終着点(notifyReparented)に揃える。
        pendingDisplayModeNotification = (.fullscreen, dims)
    }

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
            maxHeight: Double(max(0, screen.height - topReserve))
        )
    }

    /// webView 内部スクロールの動的切替(§5 H4・§6-2)。fullscreen ではカード自己スクロールを許し、
    /// inline では切る(チャット全体スクロールと二重にしない)。生成時引数でなく実行時に切替できる。
    func setWebViewScrollEnabled(_ enabled: Bool) {
        webView?.scrollView.isScrollEnabled = enabled
        // ズームロックの再適用(2026-07-17 実機 FB: fullscreen でダブルタップ拡大が復活)。
        // WKWebView はサイズ変更(inline→全画面)で viewport を再計算し、生成時に掛けた
        // 1:1 ロック(min/max zoomScale・認識器無効化)を上書きし直すことがある。この関数は
        // fullscreen⇄inline の切替点で必ず通るので、ここで毎回掛け直すのが最小の防衛線
        // (詳細は AppCardWebViewFactory.relockZoom のコメント)。
        if let webView { AppCardWebViewFactory.relockZoom(of: webView) }
    }

    /// sheet dismiss で inline へ戻す一連の処理(P4-DM・設計 04 §5 H4-E)。
    ///
    /// 【2026-07-18 監査 LOW 対応: 「固定順序」コメントの実態への訂正】旧コメントは「rehome →
    /// scrollEnabled=false → host-context-changed」を**固定順序**と称していたが、実装は
    /// displayMode 代入(同期)・setWebViewScrollEnabled(同期)のあとに Task {} で通知を投げるだけで、
    /// rehome(SwiftUI の再アダプト)自体は次の描画サイクルまで非同期に起きる。つまり
    /// 「host-context-changed が rehome より先に送られることはない」という主張は保証されておらず
    /// (Task のスケジューリングと SwiftUI 再評価の先後は不定)、コメントが実態より強く言い過ぎていた
    /// (CLAUDE.md「嘘コメントを残さない」)。
    ///
    /// 今回、監査 2026-07-18 HIGH #1(fullscreen 昇格順序バグ)の修正で導入した保留箱
    /// (pendingDisplayModeNotification)+ notifyReparented(AppCardView.onAdopted フック)は、
    /// この inline 復帰にもそのまま対称に適用できる(fullscreen→inline も「webView が新コンテナへ
    /// 実際に載ってから寸法を通知する」という同じ要請を持つため)。よってここでも直接 Task で送らず
    /// 保留箱へ積み、InlineCardView 側 AppCardView の実際の reparent 完了を待って送る形に統一した。
    /// これで「host-context-changed は実際の reparent 後」が両方向とも機械的に保証される
    /// (コメントの過大な主張の解消 = 監査 LOW 対応)。
    func restoreInline() {
        // 1. rehome: displayMode=.inline に戻すと、inline 側 AppCardView が再アダプトで webView を取り戻す
        //    (@Observable 観測で InlineCardView が再評価される。設計 04 §6-7 の rehomeToken 保険は
        //    この観測が効くので不要 —— スパイクの View 側 @State bump を @Observable の単一真実が代替する)。
        displayMode = .inline
        // 2. scrollEnabled=false: inline は高さ追従で内部スクロール不要(チャット全体でスクロールする)。
        setWebViewScrollEnabled(false)
        // 3. host-context-changed(inline + inline 寸法)は保留箱に積むだけ。実送信は inline 側
        //    AppCardView の実際の reparent 完了(onAdopted → notifyReparented)を待つ。
        let dims = ContainerDimensions(width: Double(containerWidth), maxHeight: Double(inlineMaxHeight))
        pendingDisplayModeNotification = (.inline, dims)
    }

    // MARK: - テーマ(外観)変更(#5 ダークモード)

    /// ホストの外観(colorScheme)が変わったらカードへ伝える(#5・apps.mdx:822-882)。
    /// InlineCardView が @Environment(\.colorScheme) の変化(.onChange)を検知して呼ぶ。build 前(session 未生成)や
    /// 同値のときは何もしない(冗長な host-context-changed を送らない)。
    /// 手順: ①webView の overrideUserInterfaceStyle を更新(prefers-color-scheme 用)→ ②theme/styles を
    /// 導出して session.notifyThemeChanged で host-context-changed を送る(styles トークン用)。
    func updateColorScheme(_ scheme: ColorScheme) {
        guard currentColorScheme != scheme else { return }  // 同値は無視(初回 build 時に確定済み)。
        currentColorScheme = scheme
        webView?.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        let theme = HostThemeBuilder.theme(for: scheme)
        let styles = HostThemeBuilder.styles(for: scheme)
        let session = self.session
        Task { await session?.notifyThemeChanged(theme: theme, styles: styles) }
    }
}

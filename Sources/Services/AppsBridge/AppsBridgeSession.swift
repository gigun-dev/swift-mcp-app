// MCP Appsのinitialize→initialized→teardown順序を守る、1 WKWebView単位のactor状態機械。
// initialized前のHost通知はoutboxへ積み、ready遷移時にFIFO配送する(apps.mdx:485 MUST NOT)。
// passthroughの並行処理とJSON配送は協調オブジェクトへ分離し、Sessionは順序制約だけを所有する。
import Foundation
import OSLog
import Kernel

/// request-display-modeのホスト判断。wire型へホスト固有の寸法計算を持ち込まないためServicesに置く。
public struct DisplayModeResolution: Sendable {
    /// 実際に設定するモード(拒否時は現状維持のモード。要求どおりとは限らない)。
    public let mode: UIDisplayMode
    /// 新モードでの寸法。nil なら Session 側が現行 inline 寸法(containerWidth/maxHeight)を使う。
    public let containerDimensions: ContainerDimensions?

    public init(mode: UIDisplayMode, containerDimensions: ContainerDimensions? = nil) {
        self.mode = mode
        self.containerDimensions = containerDimensions
    }
}

/// MCP Apps ホスト側のセッション状態機械。
///
/// 依存は2つだけ:
///  - `AppsBridgeTransport`(実装は `WebViewTransport`): View との postMessage 往復
///    (Host→View 配送・View→Host 受信ストリーム)。プロトコルに切ってあるのはテスト用の
///    インメモリ実装を挿せるようにするため(WebViewTransport のコメント参照・P4-DM H3)。
///  - `AppsServerProxy`: passthrough(tools/call・resources/read)を実サーバーへ流す口。
/// caldav 非依存(ツール名も structuredContent の形も知らない — 設計 §0)。
public actor AppsBridgeSession {
    // MARK: - 状態

    /// ライフサイクル状態(設計 §2 の enum)。
    public enum State: Sendable, Equatable {
        case loadingResource     // resources/read 中(HTML 未ロード)。生成直後の初期値。
        case awaitingInitialize  // HTML ロード済み・ui/initialize 待ち。
        case ready               // initialized 受信済み — outbox を flush、以後は即送信。
        case tearingDown         // resource-teardown 送信済み・応答待ち(タイムアウト付き)。
        case closed              // 終了。
    }

    private var state: State = .loadingResource

    // ready 前に積まれた Host→View 通知。ready 遷移で FIFO flush(仕様 MUST NOT の機械的遵守)。
    private var outbox = AppsBridgeOutbox()

    // MARK: - 協調オブジェクト

    private let transport: any AppsBridgeTransport
    private let delivery: AppsBridgeDelivery
    // HOLB S0: 具象 AppsServerProxy でなくプロトコル越しに持つ。テストでゲート式モックを挿し、
    // passthrough 往復 await 中に size-changed を interleave できるかを決定的に固定するため。
    // 生成箇所は具象 AppsServerProxy(actor= AppsServerProxying 適合)を渡すので本番挙動は不変。
    private let passthroughDispatcher: AppsBridgePassthroughDispatcher
    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "appssession")

    // initialize 応答に載せる Host 情報と hostContext の材料(設計 §2/§3-2 の最小集合)。
    private let hostInfo: Implementation
    // コンテナ寸法。幅はホスト固定(設計 §5)。size-changed の width は無視し、幅変化は
    // AppCardView からの setContainerWidth 経由でのみ更新する。
    private var containerWidth: Double
    private let maxHeight: Double

    // initialize応答と変更通知に使うテーマの影。単一の真実はFeatures側のcolorScheme。
    private var currentTheme: UITheme
    private var currentStyles: HostStyles?

    // size-changed の height を Features(AppCardView)へ流すコールバック。
    // actor から MainActor の @Observable を直接触らないための注入点(設計 §5)。
    private let onSizeChanged: @Sendable (Double) async -> Void

    // カードのfullscreen申告(apps.mdx:786)をFeaturesへ渡し、非対応カードの死にボタンを防ぐ。
    private let onCardCapabilities: (@Sendable (_ supportsFullscreen: Bool) async -> Void)?

    // initialize 後に View capability を保持するため var。判定責務は responder 内へ閉じ込める。
    private var interactionResponder: AppsBridgeInteractionResponder

    // 現在の displayMode(Session が最後に View へ通知した値)。単一の真実は将来
    // Features 側(InlineCardHost)に置く設計(設計 04 §3 責務表)だが、Session は
    // 「変化したときだけ host-context-changed を送る」ための相関に自分の記憶が要る
    // (Features の実際の UI 状態の「影」であって、真実そのものではない)。
    private var currentDisplayMode: UIDisplayMode = .inline

    // teardown の応答待ち continuation とその id(応答相関に使う)。
    private let teardownWaiter = TeardownResponseWaiter()

    // Host→View request(teardown)に振る id 採番。負値を使い View 由来 id と衝突させない。
    private var hostRequestIDs = HostRequestIDGenerator()

    private var consumeTask: Task<Void, Never>?

    // テスト専用の readiness プローブ。ready 遷移(initialized 受信→outbox flush)は受信ループの非同期消化に
    // 依存するため、テストが「ready になったか」を決定的に待つ手段が要る。HOLB テストで並行スケジューリング
    // 負荷が増え、Task.yield 1回では ready 到達前に次操作へ進むレースが顕在化した(pre-existing latent
    // flakiness の顕在化)。本番経路は一切使わない。
    var isReadyForTests: Bool { state == .ready }

    public init(
        transport: any AppsBridgeTransport,
        proxy: any AppsServerProxying,
        hostInfo: Implementation = Implementation(name: "MCPHost", version: "0.1.0"),
        containerWidth: Double,
        maxHeight: Double = 600,
        // 初期theme/stylesはFeaturesがcolorSchemeから導出する。
        theme: UITheme = .light,
        styles: HostStyles? = nil,
        onSizeChanged: @escaping @Sendable (Double) async -> Void = { _ in },
        onDisplayModeRequested: (@Sendable (UIDisplayMode) async -> DisplayModeResolution)? = nil,
        onCardCapabilities: (@Sendable (_ supportsFullscreen: Bool) async -> Void)? = nil,
        // カード発tools/callのハプティクスフック。
        onCardToolCall: (@Sendable () async -> Void)? = nil,
        // ui/open-link の実行フック(既定 nil = 常に拒否)。本番は Features が UIApplication.open へ配線する。
        onOpenLink: (@Sendable (URL) async -> Bool)? = nil
    ) {
        self.transport = transport
        self.delivery = AppsBridgeDelivery(transport: transport)
        self.passthroughDispatcher = AppsBridgePassthroughDispatcher(
            transport: transport,
            proxy: proxy,
            onCardToolCall: onCardToolCall
        )
        self.hostInfo = hostInfo
        self.containerWidth = containerWidth
        self.maxHeight = maxHeight
        self.currentTheme = theme
        self.currentStyles = styles
        self.onSizeChanged = onSizeChanged
        self.onCardCapabilities = onCardCapabilities
        self.interactionResponder = AppsBridgeInteractionResponder(
            onDisplayModeRequested: onDisplayModeRequested,
            onOpenLink: onOpenLink
        )
    }

    // MARK: - 起動 / 受信ループ

    /// transport.incoming の消費を開始する。HTML ロード後・ここで awaitingInitialize に入る。
    /// 二重起動しても副作用が無いよう guard する。
    public func start() {
        guard consumeTask == nil else { return }
        // HTML はこの直前に Features 側が loadHTMLString している前提。ここから initialize 待ち。
        state = .awaitingInitialize
        logger.notice("session start: awaitingInitialize(ui/initialize を待つ)")
        consumeTask = Task { [weak self] in
            guard let self else { return }
            // transport.incoming は (message, raw) のタプル。ここでは判別済み message だけ使う。
            for await item in self.transport.incoming {
                await self.handleIncoming(item.message)
            }
        }
    }

    /// コンテナ幅の変化を View に伝える(host-context-changed・設計 §5)。
    /// ready 前は「initialize で返す幅」を更新するだけ(まだ何も送らない = MUST NOT)。
    public func setContainerWidth(_ width: Double) async {
        containerWidth = width
        guard state == .ready else {
            logger.notice("setContainerWidth: ready 前なので initialize 値のみ更新 width=\(width)")
            return
        }
        // hostContext の部分更新。containerDimensions だけを載せる(設計 §5)。
        let patch = HostContext(containerDimensions: ContainerDimensions(width: width, maxHeight: maxHeight))
        let note = JSONRPCNotification(
            method: AppsMethod.hostContextChanged,
            params: try? JSONValue(encoding: patch))
        await delivery.send(note)
        logger.notice("host-context-changed 送信 width=\(width)")
    }

    /// ホスト起点の displayMode 変更(sheet dismiss で inline へ戻す等・P4-DM 設計 04 §5 H3)。
    /// View 発の request-display-mode と違い応答は無く、host-context-changed 通知だけ送る
    /// (apps.mdx:776)。H4(Features の sheet 器)未実装の現時点では誰も呼ばないが、
    /// H3 の API としてここに用意しておく。
    public func notifyDisplayModeChanged(
        to mode: UIDisplayMode,
        containerDimensions: ContainerDimensions? = nil
    ) async {
        guard state == .ready else {
            // ready 前(MUST NOT の対象)は送らず、記憶だけ更新する。setContainerWidth の
            // ready-前分岐と同じ考え方(design 04 §5 H3・ready 後の再遷移で改めて通知される想定)。
            currentDisplayMode = mode
            logger.notice("notifyDisplayModeChanged: ready 前なので記憶のみ更新 mode=\(String(describing: mode))")
            return
        }
        currentDisplayMode = mode
        let dims = containerDimensions ?? ContainerDimensions(width: containerWidth, maxHeight: maxHeight)
        let patch = HostContext(displayMode: mode, containerDimensions: dims)
        await delivery.send(JSONRPCNotification(
            method: AppsMethod.hostContextChanged, params: try? JSONValue(encoding: patch)))
        logger.notice("host-context-changed 送信(ホスト起点) mode=\(String(describing: mode))")
    }

    /// ホストの外観(colorScheme)変更を View へ伝える(#5 ダークモード・apps.mdx:822-882)。
    /// theme と styles(部分更新)だけを載せた host-context-changed を送る。setContainerWidth と同じく、
    /// ready 前は「initialize で返す値」を更新するだけで送らない(MUST NOT の機械的遵守・apps.mdx:485)。
    ///
    /// 【なぜ Features から値を受けるのか】theme/styles の導出は UIColor(UIKit)や SwiftUI colorScheme に
    /// 依存し、Services/actor には持ち込めない。Session は「受けた値を反映するだけ」に留め、導出は
    /// Features(InlineCardHost + HostThemeBuilder)に置く(CLAUDE.md のレイヤー方針・設計 04 責務表)。
    public func notifyThemeChanged(theme: UITheme, styles: HostStyles?) async {
        // 記憶を先に更新(ready 前でも、後続の initialize が最新値で応答できるように)。
        currentTheme = theme
        currentStyles = styles
        guard state == .ready else {
            logger.notice("notifyThemeChanged: ready 前なので initialize 値のみ更新 theme=\(theme.rawValue)")
            return
        }
        // 部分更新(spec: params は「変わったフィールドだけ」の Partial context)。theme と styles だけ載せる。
        let patch = HostContext(theme: theme, styles: styles)
        await delivery.send(JSONRPCNotification(
            method: AppsMethod.hostContextChanged, params: try? JSONValue(encoding: patch)))
        logger.notice("host-context-changed 送信(theme 変更) theme=\(theme.rawValue)")
    }

    // MARK: - 片付け(設計 §4/§5)

    /// resource-teardown を送り、応答 or タイムアウト(既定 2s)後に closed へ遷移する。
    /// ready でない場合は握手が終わっていない = 送っても無駄なので即 closed にする。
    public func teardown(timeout: Duration = .seconds(2)) async {
        guard state == .ready else {
            logger.notice("teardown: ready でないので即 closed(state=\(String(describing: self.state)))")
            await close()
            return
        }
        state = .tearingDown
        let id = RequestID.int(hostRequestIDs.make())
        await teardownWaiter.begin(requestID: id)
        let request = JSONRPCRequest(
            id: id,
            method: AppsMethod.resourceTeardown,
            params: try? JSONValue(encoding: ResourceTeardownParams()))
        logger.notice("resource-teardown 送信 id=\(String(describing: id))")

        // 応答 or タイムアウトのどちらか早い方で先に進む。
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await self?.teardownWaiter.wait()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            // request をここで投げる(応答待ちタスク登録より後でも、応答は continuation で待つので競合しない)。
            if let data = try? JSONEncoder().encode(request) {
                // JSONEncoder出力はUTF-8保証済み。失敗しない文字列化を使う。
                // swiftlint:disable:next optional_data_string_conversion
                await self.transport.deliver(rawJSON: String(decoding: data, as: UTF8.self))
            }
            // 最初に終わった一方で group を畳む(残りは破棄)。
            await group.next()
            group.cancelAll()
        }
        // teardown 応答の continuation がまだ生きていれば(タイムアウト勝ち)ここで解放。
        await teardownWaiter.release()
        logger.notice("teardown 完了 → closed")
        await close()
    }

    /// 明示クローズ(webView 破棄時など)。ストリームを閉じ、以後の送受信を止める。
    public func close() async {
        guard state != .closed else { return }
        state = .closed
        consumeTask?.cancel()
        consumeTask = nil
        // HOLB S2: 実行中の passthrough Task を全 cancel しテーブルクリア(consumeTask 停止と同じ寿命管理)。
        // cancel されても各 Task は proxyRequest 内の closed ガードで配送を握り潰すので破棄後の配送は起きない。
        await passthroughDispatcher.close()
        transport.finish()
    }

    // MARK: - 受信ディスパッチ(View→Host)

    private func handleIncoming(_ message: JSONRPCMessage) async {
        // Kernel の2レーン分類。malformed(typed の params デコード失敗)は throw されるので
        // ここで握って onerror 相当のログに落とす(設計 §1: transport は黙殺・昇格は状態機械の仕事)。
        let classified: IncomingViewMessage
        do {
            classified = try IncomingViewMessage.classify(message)
        } catch {
            logger.error("classify 失敗(malformed): \(String(reflecting: error), privacy: .public)")
            return
        }

        switch classified {
        case let .typed(typed):
            await handleTyped(typed)
        case let .passthrough(method, id, params):
            await passthroughDispatcher.dispatch(method: method, id: id, params: params)
        case let .response(response):
            if await teardownWaiter.receive(response) {
                logger.notice("resource-teardown 応答受信")
            } else {
                logger.notice("相関先の無い response id=\(String(describing: response.id))(無視)")
            }
        }
    }

    private func handleTyped(_ typed: TypedViewMessage) async {
        switch typed {
        case let .initialize(id, params):
            await handleInitialize(id: id, params: params)

        case .initialized:
            // ready へ遷移し outbox を flush。ここが「送信解禁」の唯一の起点。
            logger.notice("ui/notifications/initialized 受信 → ready 遷移・outbox flush(件数=\(self.outbox.count))")
            state = .ready
            let pending = outbox.drain()
            await delivery.send(pending)
            if !pending.isEmpty { logger.notice("outbox flush 完了(\(pending.count) 件)") }

        case let .sizeChanged(params):
            // 高さだけ採用(幅はホスト固定・設計 §5)。height が来たら Features へ流す。
            if let height = params.height {
                logger.notice("size-changed 受信 height=\(height)(width は無視)")
                await onSizeChanged(height)
            }

        case let .openLink(id, params):
            let response = await interactionResponder.openLink(id: id, params: params)
            await delivery.send(response)

        case let .requestDisplayMode(id, params):
            let response = await interactionResponder.displayMode(
                id: id,
                params: params,
                currentMode: currentDisplayMode
            )
            await delivery.send(response)
        }
    }

    private func handleInitialize(id: RequestID, params: InitializeParams) async {
        // 応答より先に保存し、直後の request-display-mode でも宣言を必ず参照する。
        interactionResponder.configureDisplayModes(AppsBridgeInitializeBuilder.declaredDisplayModes(params))
        let context = AppsBridgeInitializeBuilder.Context(
            hostInfo: hostInfo,
            theme: currentTheme,
            styles: currentStyles,
            displayMode: currentDisplayMode,
            containerWidth: containerWidth,
            maxHeight: maxHeight,
            supportsDisplayModeRequests: interactionResponder.supportsDisplayModeRequests
        )
        do {
            let result = try AppsBridgeInitializeBuilder.result(params: params, context: context)
            await delivery.send(JSONRPCResponse(id: id, result: result))
        } catch {
            let error = JSONRPCError(code: -32603, message: "initialize result のエンコードに失敗")
            await delivery.send(JSONRPCResponse(id: id, error: error))
        }

        let supportsFullscreen = AppsBridgeInitializeBuilder.supportsFullscreen(params)
        await onCardCapabilities?(supportsFullscreen)
        logger.notice("カード capability 判定: supportsFullscreen=\(supportsFullscreen)")
    }

    // MARK: - outbox / 配送ヘルパ

    /// ready なら即送信、そうでなければ outbox に積む(MUST NOT の機械的遵守)。
    func enqueueOrSend(_ note: JSONRPCNotification, label: String) async {
        if state == .ready {
            await delivery.send(note)
            logger.notice("\(label, privacy: .public) 即送信(ready)")
        } else {
            outbox.append(note)
            logger.notice("\(label, privacy: .public) を outbox に退避 state=\(String(describing: self.state))")
            logger.notice("outbox 現在 \(self.outbox.count) 件")
        }
    }
}

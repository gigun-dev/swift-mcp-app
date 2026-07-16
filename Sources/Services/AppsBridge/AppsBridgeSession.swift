// MCP Apps のライフサイクル状態機械(設計 §2)。1 セッション = 1 WKWebView = 1 ツールカード。
//
// 仕様の順序制約(apps.mdx:485):
//   View → `ui/initialize`(request) → Host が hostContext 入り result を返す
//        → View → `ui/notifications/initialized` → **それまで Host は View に
//          いかなる request/notification も送ってはならない(MUST NOT)**。
//   破棄前は Host → `ui/resource-teardown`(request)(app-bridge.ts:811-827)。
//
// この MUST NOT を「機械的に」守るために、ready 前の Host→View 通知(tool-input/tool-result/
// host-context-changed)はすべて outbox に積み、initialized 受信で ready へ遷移した瞬間に
// FIFO で flush する。ready 前に View へ1バイトも送らないことがコードで保証される。
//
// スレッド/隔離(設計 §2 + S2 申し送り): このセッションは actor。WKWebView 操作は
// WebViewTransport.deliver 内で MainActor へホップ済み(WebViewTransport のコメント参照)なので、
// ここは actor のまま transport.deliver を await するだけでよい。
import Foundation
import OSLog
import Kernel

/// request-display-mode の解決結果(P4-DM・設計 04 §5 H3)。Kernel の wire 型
/// (RequestDisplayModeResult 等)とは別に Services 側で持つ小さな struct —— containerDimensions
/// という「結果に付随する追加情報」を wire 型に足すと Kernel が displayMode ごとの寸法計算という
/// ホスト側の判断ロジックを知ることになり、Kernel のプラットフォーム非依存性(CLAUDE.md)を汚す。
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
    private var outbox: [JSONRPCNotification] = []

    // MARK: - 協調オブジェクト

    private let transport: any AppsBridgeTransport
    // HOLB S0: 具象 AppsServerProxy でなくプロトコル越しに持つ。テストでゲート式モックを挿し、
    // passthrough 往復 await 中に size-changed を interleave できるかを決定的に固定するため。
    // 生成箇所は具象 AppsServerProxy(actor= AppsServerProxying 適合)を渡すので本番挙動は不変。
    private let proxy: any AppsServerProxying
    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "appssession")

    // initialize 応答に載せる Host 情報と hostContext の材料(設計 §2/§3-2 の最小集合)。
    private let hostInfo: Implementation
    // コンテナ寸法。幅はホスト固定(設計 §5)。size-changed の width は無視し、幅変化は
    // AppCardView からの setContainerWidth 経由でのみ更新する。
    private var containerWidth: Double
    private let maxHeight: Double

    // size-changed の height を Features(AppCardView)へ流すコールバック。
    // actor から MainActor の @Observable を直接触らないための注入点(設計 §5)。
    private let onSizeChanged: @Sendable (Double) async -> Void

    // request-display-mode を受けたとき、実際にどのモードへ遷移するかを決める注入点
    // (P4-DM・設計 04 §5 H3 + H4-F)。Features(H4)が sheet 器を持つかどうかを知っているのは
    // Features 側なので、Session 自身は「昇格してよいか」を判断しない。
    //
    // 【optional にした理由(設計 04 §5 H3 追補「fullscreen 広告はハンドラ注入時のみ」= H4-F)】
    // fullscreen の広告は「このハンドラが注入されたときだけ」にする。ハンドラが無い(nil)= sheet 器を
    // 持たないホスト構成では fullscreen を広告しない([inline] だけ)ことで、「押すと必ず拒否される
    // 死にボタン」を構造的に排除する(availableDisplayModes に fullscreen が出る ⇔ 実際に昇格できる、を
    // 一致させる)。nil のとき request-display-mode が来ても現状維持(currentDisplayMode)を応答して
    // 安全に拒否する(spec 上は View が apps.mdx:786 の MUST を守れば非広告モードへ要求してこないが、
    // 来ても壊れない)。本番 InlineCardHost は常にこのハンドラを注入するので fullscreen が広告される。
    private let onDisplayModeRequested: (@Sendable (UIDisplayMode) async -> DisplayModeResolution)?

    // 現在の displayMode(Session が最後に View へ通知した値)。単一の真実は将来
    // Features 側(InlineCardHost)に置く設計(設計 04 §3 責務表)だが、Session は
    // 「変化したときだけ host-context-changed を送る」ための相関に自分の記憶が要る
    // (Features の実際の UI 状態の「影」であって、真実そのものではない)。
    private var currentDisplayMode: UIDisplayMode = .inline

    // teardown の応答待ち continuation とその id(応答相関に使う)。
    private var teardownContinuation: CheckedContinuation<Void, Never>?
    private var teardownRequestID: RequestID?

    // Host→View request(teardown)に振る id 採番。負値を使い View 由来 id と衝突させない。
    private var nextHostRequestID = -1

    private var consumeTask: Task<Void, Never>?

    // 実行中の passthrough(tools/call・resources/read)の追跡テーブル(HOLB S1)。
    // なぜ passthrough だけ非直列化するのか(Why・順序不変条件):
    //   - typed/response レーンは直列でなければならない: initialize→initialized→outbox flush の直列性と
    //     teardown の request↔response 相関が受信順処理に依存する。順序を崩すと ready ゲートの機械的遵守や
    //     teardown 相関が壊れる。
    //   - passthrough の応答は id 相関で順不同 OK: tools/call/resources/read は JSON-RPC id で一意相関する
    //     ので、複数を並行に流し到着順に応答しても View は正しく突き合わせる。よって passthrough だけは
    //     「実サーバー往復 await 中に後続の size-changed 等を先に処理させてよい」。これで実機 ~730ms の
    //     head-of-line blocking が消える。
    // 実装(追跡付き非構造化 Task): UUID 採番して Task 登録・完了時に自身を除去。actor リエントランシーで
    // Task が proxy 往復を await 中、受信ループは即次メッセージへ進み typed/notification が interleave できる。
    // close() で全 Task cancel(寿命 S2)。
    // Why not(back-pressure のハード上限を今は設けない): 暴走的な tools/call 連打はサンドボックス(WKWebView)
    // 側の脅威モデルで扱う領域。上限を入れるならここ(登録前に inflightPassthrough.count を見て超過なら
    // proxyRequest を呼ばず JSONRPCError(code: -32000) を即 deliver)。今は素直に無制限で持つ。
    private var inflightPassthrough: [UUID: Task<Void, Never>] = [:]

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
        onSizeChanged: @escaping @Sendable (Double) async -> Void = { _ in },
        // 既定 nil = fullscreen を広告しない・request-display-mode は拒否(H4-F)。本番は Features が注入する。
        onDisplayModeRequested: (@Sendable (UIDisplayMode) async -> DisplayModeResolution)? = nil
    ) {
        self.transport = transport
        self.proxy = proxy
        self.hostInfo = hostInfo
        self.containerWidth = containerWidth
        self.maxHeight = maxHeight
        self.onSizeChanged = onSizeChanged
        self.onDisplayModeRequested = onDisplayModeRequested
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
            for await item in await self.transport.incoming {
                await self.handleIncoming(item.message)
            }
        }
    }

    // MARK: - Host→View API(basic-host implementation.ts:229/235 と同じ語彙)

    /// ツール入力(arguments)を tool-input 通知として送る。ready 前なら outbox へ積む。
    public func sendToolInput(arguments: JSONValue) async {
        let params = ToolInputParams(arguments: arguments)
        let note = JSONRPCNotification(
            method: AppsMethod.toolInput,
            params: try? JSONValue(encoding: params))
        await enqueueOrSend(note, label: "tool-input")
    }

    /// ツール結果(CallToolResult 相当の JSON をそのまま)を tool-result 通知として送る。
    /// params は CallToolResult を **JSONValue のまま素通し**(設計 §3 のロスレス要件)。
    public func sendToolResult(_ raw: JSONValue) async {
        let note = JSONRPCNotification(method: AppsMethod.toolResult, params: raw)
        await enqueueOrSend(note, label: "tool-result")
    }

    /// ツールキャンセルを送る(結果取得に失敗したとき等)。
    public func sendToolCancelled(reason: String) async {
        let params = ToolCancelledParams(reason: reason)
        let note = JSONRPCNotification(
            method: AppsMethod.toolCancelled,
            params: try? JSONValue(encoding: params))
        await enqueueOrSend(note, label: "tool-cancelled")
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
        await deliver(notification: note)
        logger.notice("host-context-changed 送信 width=\(width)")
    }

    /// ホスト起点の displayMode 変更(sheet dismiss で inline へ戻す等・P4-DM 設計 04 §5 H3)。
    /// View 発の request-display-mode と違い応答は無く、host-context-changed 通知だけ送る
    /// (apps.mdx:776)。H4(Features の sheet 器)未実装の現時点では誰も呼ばないが、
    /// H3 の API としてここに用意しておく。
    public func notifyDisplayModeChanged(to mode: UIDisplayMode, containerDimensions: ContainerDimensions? = nil) async {
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
        await deliver(notification: JSONRPCNotification(
            method: AppsMethod.hostContextChanged, params: try? JSONValue(encoding: patch)))
        logger.notice("host-context-changed 送信(ホスト起点) mode=\(String(describing: mode))")
    }

    // MARK: - 片付け(設計 §4/§5)

    /// resource-teardown を送り、応答 or タイムアウト(既定 2s)後に closed へ遷移する。
    /// ready でない場合は握手が終わっていない = 送っても無駄なので即 closed にする。
    public func teardown(timeout: Duration = .seconds(2)) async {
        guard state == .ready else {
            logger.notice("teardown: ready でないので即 closed(state=\(String(describing: self.state)))")
            close()
            return
        }
        state = .tearingDown
        let id = RequestID.int(makeHostRequestID())
        teardownRequestID = id
        let request = JSONRPCRequest(
            id: id,
            method: AppsMethod.resourceTeardown,
            params: try? JSONValue(encoding: ResourceTeardownParams()))
        logger.notice("resource-teardown 送信 id=\(String(describing: id))")

        // 応答 or タイムアウトのどちらか早い方で先に進む。
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                await self?.awaitTeardownResponse()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            // request をここで投げる(応答待ちタスク登録より後でも、応答は continuation で待つので競合しない)。
            if let data = try? JSONEncoder().encode(request) {
                await self.transport.deliver(rawJSON: String(decoding: data, as: UTF8.self))
            }
            // 最初に終わった一方で group を畳む(残りは破棄)。
            await group.next()
            group.cancelAll()
        }
        // teardown 応答の continuation がまだ生きていれば(タイムアウト勝ち)ここで解放。
        if let cont = teardownContinuation {
            teardownContinuation = nil
            cont.resume()
        }
        logger.notice("teardown 完了 → closed")
        close()
    }

    /// 明示クローズ(webView 破棄時など)。ストリームを閉じ、以後の送受信を止める。
    public func close() {
        guard state != .closed else { return }
        state = .closed
        consumeTask?.cancel()
        consumeTask = nil
        // HOLB S2: 実行中の passthrough Task を全 cancel しテーブルクリア(consumeTask 停止と同じ寿命管理)。
        // cancel されても各 Task は proxyRequest 内の closed ガードで配送を握り潰すので破棄後の配送は起きない。
        for task in inflightPassthrough.values { task.cancel() }
        inflightPassthrough.removeAll()
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
            // HOLB S1: passthrough は await せず追跡付き Task へ逃がす。ここで await すると proxy 往復が終わるまで
            // 受信ループが止まり、直後の size-changed が詰まる(実機 ~730ms)。Task 登録後は即 return し次メッセージへ。
            // [weak self]: 既存流儀(consumeTask)に合わせる。actor が Task を保持する構造で強参照でもリークしないが、
            // consumeTask と同じく弱参照で統一し「Session が Task を生かし続ける」誤読を避ける(自己参照の輪を作らない)。
            let key = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                await self.handlePassthrough(method: method, id: id, params: params)
                await self.removeInflightPassthrough(key)
            }
            inflightPassthrough[key] = task
        case let .response(response):
            handleResponse(response)
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
            await flushOutbox()

        case let .sizeChanged(params):
            // 高さだけ採用(幅はホスト固定・設計 §5)。height が来たら Features へ流す。
            if let height = params.height {
                logger.notice("size-changed 受信 height=\(height)(width は無視)")
                await onSizeChanged(height)
            }

        case let .openLink(id, params):
            // open-link は「実装1行」の約束(設計 §3-2)。ただし UIApplication.open は UIKit 依存で
            // Services には持ち込めない。ここでは受理応答({})だけ返し、実際に開くのは Features 側の
            // 責務にする余地を残す(スパイクでは todos カードは外部リンクを踏まないので未配線)。
            // TODO(P3): open-link を Features のハンドラへ委譲する注入点を足す。
            logger.notice("open-link 受信 url=\(params.url, privacy: .public)(スパイクでは受理のみ)")
            await deliver(response: JSONRPCResponse(id: id, result: .object([:])))

        case let .requestDisplayMode(id, params):
            // カード発のモード変更要求。Features(H4)が実モードを決めて返す。既定は拒否(inline)。
            // ハンドラ未注入(nil = fullscreen 非広告構成)なら現状維持を応答して拒否する(H4-F)。
            let resolution = await onDisplayModeRequested?(params.mode)
                ?? DisplayModeResolution(mode: currentDisplayMode)
            // apps.mdx:787 MUST: 変えなかった場合も「結果のモード」を必ず返す。
            let result = RequestDisplayModeResult(mode: resolution.mode)
            await deliver(response: JSONRPCResponse(
                id: id, result: (try? JSONValue(encoding: result)) ?? .object([:])))
            // モードが実際に変わったときだけ host-context-changed で通知(apps.mdx:776)。
            if resolution.mode != currentDisplayMode {
                currentDisplayMode = resolution.mode
                let dims = resolution.containerDimensions
                    ?? ContainerDimensions(width: containerWidth, maxHeight: maxHeight)
                let patch = HostContext(displayMode: resolution.mode, containerDimensions: dims)
                await deliver(notification: JSONRPCNotification(
                    method: AppsMethod.hostContextChanged, params: try? JSONValue(encoding: patch)))
                logger.notice("displayMode 変更 → \(String(describing: resolution.mode)) を host-context-changed で通知")
            }
        }
    }

    /// ui/initialize への応答。hostContext(theme/locale/displayMode/containerDimensions/
    /// availableDisplayModes)を載せて result を返す(設計 §2)。
    private func handleInitialize(id: RequestID, params: InitializeParams) async {
        logger.notice("ui/initialize 受信 appInfo=\(params.appInfo.name, privacy: .public) proto=\(params.protocolVersion, privacy: .public)")

        // availableDisplayModes: fullscreen は onDisplayModeRequested ハンドラが注入されたときだけ
        // 広告する(設計 04 §5 H3 追補「fullscreen 広告はハンドラ注入時のみ」= H4-F)。nil = sheet 器の
        // 無いホスト構成では [inline] だけを広告し、「押すと必ず拒否される死にボタン」を排除する。
        // pip は見送り(設計 04 §4 ボツ案 — ユースケースが薄く、host-context-changed の寸法契約も未整理)。
        let availableModes: [UIDisplayMode] = onDisplayModeRequested != nil ? [.inline, .fullscreen] : [.inline]
        let hostContext = HostContext(
            theme: .light,
            locale: "ja-JP",
            displayMode: currentDisplayMode,
            availableDisplayModes: availableModes,
            containerDimensions: ContainerDimensions(width: containerWidth, maxHeight: maxHeight))

        // protocolVersion は View が送ってきたものをそのまま返す(バージョン交渉はスパイク外・
        // 同一版を echo するのが最小の合法応答)。hostCapabilities は最小(空オブジェクト)。
        let result = InitializeResult(
            protocolVersion: params.protocolVersion,
            hostInfo: hostInfo,
            hostCapabilities: .object([:]),
            hostContext: hostContext)

        if let resultJSON = try? JSONValue(encoding: result) {
            await deliver(response: JSONRPCResponse(id: id, result: resultJSON))
            logger.notice("ui/initialize 応答済み(availableDisplayModes=\(availableModes.map(\.rawValue), privacy: .public))")
        } else {
            await deliver(response: JSONRPCResponse(
                id: id, error: JSONRPCError(code: -32603, message: "initialize result のエンコードに失敗")))
        }
    }

    /// passthrough レーン(tools/call・resources/read・ping・未知)。状態を持たない素通しプロキシ。
    private func handlePassthrough(method: String, id: RequestID?, params: JSONValue?) async {
        switch method {
        case AppsMethod.toolsCall:
            await proxyRequest(id: id, label: "tools/call") {
                try await self.proxy.passthroughToolsCall(params: params)
            }

        case AppsMethod.resourcesRead:
            await proxyRequest(id: id, label: "resources/read") {
                try await self.proxy.passthroughResourcesRead(params: params)
            }

        case AppsMethod.ping:
            // ping はホストが自分で答える(空 result)。サーバーへは流さない。
            if let id { await deliver(response: JSONRPCResponse(id: id, result: .object([:]))) }

        default:
            // 未知メソッド。request には -32601、notification はログのみ(設計 §2)。
            if let id {
                logger.error("未知 request method=\(method, privacy: .public) → -32601")
                await deliver(response: JSONRPCResponse(id: id, error: JSONRPCError.methodNotFound(method)))
            } else {
                logger.notice("未知 notification method=\(method, privacy: .public)(黙殺)")
            }
        }
    }

    /// passthrough リクエストの共通処理: プロキシを呼び、成功なら result、失敗なら error を返す。
    /// notification(id なし)で来た passthrough はサーバーへ流すが応答は返せないので投げっぱなし。
    private func proxyRequest(id: RequestID?, label: String, _ work: @Sendable () async throws -> JSONValue) async {
        do {
            let result = try await work()
            // HOLB S1: 往復 await から戻った時点で closed(webView 破棄後)なら配送しない。非直列化で往復中に
            // close() が走りうる=応答到着時に配送先 View が無いレース。closed への配送は無意味なので握り潰す。
            // Why not tearingDown も弾く: teardown 中は View がまだ生存しているので配送は許容する。
            guard state != .closed else {
                logger.notice("\(label, privacy: .public) 応答破棄(往復完了時に既に closed)")
                return
            }
            if let id {
                await deliver(response: JSONRPCResponse(id: id, result: result))
                logger.notice("\(label, privacy: .public) 素通し応答済み")
            } else {
                logger.notice("\(label, privacy: .public) 通知として素通し(応答なし)")
            }
        } catch {
            logger.error("\(label, privacy: .public) 素通し失敗: \(String(reflecting: error), privacy: .public)")
            if let id {
                // -32603 = Internal error。サーバー起因の失敗を View へ透過的に伝える。
                await deliver(response: JSONRPCResponse(
                    id: id, error: JSONRPCError(code: -32603, message: "\(label) 失敗: \(error)")))
            }
        }
    }

    /// View からの応答(ホストが投げた teardown への返答など)を相関して解消する。
    private func handleResponse(_ response: JSONRPCResponse) {
        if let expected = teardownRequestID, response.id == expected {
            logger.notice("resource-teardown 応答受信")
            teardownRequestID = nil
            if let cont = teardownContinuation {
                teardownContinuation = nil
                cont.resume()
            }
        } else {
            // 相関先の無い応答。ホストは teardown 以外の request を View に投げていないので通常来ない。
            logger.notice("相関先の無い response id=\(String(describing: response.id))(無視)")
        }
    }

    // MARK: - outbox / 配送ヘルパ

    /// ready なら即送信、そうでなければ outbox に積む(MUST NOT の機械的遵守)。
    private func enqueueOrSend(_ note: JSONRPCNotification, label: String) async {
        if state == .ready {
            await deliver(notification: note)
            logger.notice("\(label, privacy: .public) 即送信(ready)")
        } else {
            outbox.append(note)
            logger.notice("\(label, privacy: .public) を outbox に退避(state=\(String(describing: self.state)) 現在 \(self.outbox.count) 件)")
        }
    }

    /// outbox を FIFO で flush する。ready 遷移直後にのみ呼ぶ。
    private func flushOutbox() async {
        let pending = outbox
        outbox.removeAll()
        for note in pending {
            await deliver(notification: note)
        }
        if !pending.isEmpty {
            logger.notice("outbox flush 完了(\(pending.count) 件)")
        }
    }

    private func deliver(notification: JSONRPCNotification) async {
        guard let data = try? JSONEncoder().encode(notification) else { return }
        await transport.deliver(rawJSON: String(decoding: data, as: UTF8.self))
    }

    private func deliver(response: JSONRPCResponse) async {
        await transport.deliver(response: response)
    }

    private func awaitTeardownResponse() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // すでに応答済み(相関が先に解消)なら即 resume。そうでなければ保持して待つ。
            if teardownRequestID == nil {
                continuation.resume()
            } else {
                teardownContinuation = continuation
            }
        }
    }

    // HOLB S1: 完了した passthrough Task を追跡テーブルから外す(Task の末尾で自身を除去)。
    private func removeInflightPassthrough(_ key: UUID) {
        inflightPassthrough[key] = nil
    }

    private func makeHostRequestID() -> Int {
        let id = nextHostRequestID
        nextHostRequestID -= 1
        return id
    }
}

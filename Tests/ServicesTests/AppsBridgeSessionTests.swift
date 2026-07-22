// AppsBridgeSession の displayMode ネゴシエーション(P4-DM・設計 04 §5 H3)の単体テスト。
//
// テスト方針(CLAUDE.md「テスト = What」): 実 WKWebView は使わない(webView 未 attach だと
// WebViewTransport.deliver は何もせず抜けるため、送信内容を観測できない — WebViewTransport の
// AppsBridgeTransport コメント参照)。代わりに `MockTransport`(このファイル内)を
// `AppsBridgeTransport` として注入し、Host→View 配送(生 JSON)を配列にキャプチャして検証する。
//
// AppsServerProxy は tools/call・resources/read の passthrough にしか使わないので、
// displayMode のテストでは未接続の `Client` を渡すだけで十分(AppsServerProxyTests と同じ流儀)。
import Foundation
import Testing
import MCP

@testable import Kernel
@testable import Services

/// `AppsBridgeTransport` のインメモリ実装。View→Host は `push` で注入し、Host→View は
/// `sentRawJSON` に蓄積する(FIFO・送信順序をそのままテストで検証できる)。
final class MockTransport: AppsBridgeTransport, @unchecked Sendable {
    let incoming: AsyncStream<(message: JSONRPCMessage, raw: String)>
    private let continuation: AsyncStream<(message: JSONRPCMessage, raw: String)>.Continuation

    // deliver で来た生 JSON を到着順に積む。テストはこれをデコードして検証する。
    private(set) var sentRawJSON: [String] = []

    init() {
        var continuation: AsyncStream<(message: JSONRPCMessage, raw: String)>.Continuation!
        self.incoming = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    /// View→Host メッセージを1件注入する(JSON 文字列から Kernel の判別を通す)。
    func push(_ json: String) {
        guard let message = try? JSONRPCMessage.decode(from: Data(json.utf8)) else {
            Issue.record("MockTransport.push: decode 失敗 json=\(json)")
            return
        }
        continuation.yield((message: message, raw: json))
    }

    func deliver(rawJSON: String) async {
        sentRawJSON.append(rawJSON)
    }

    func deliver(response: JSONRPCResponse) async {
        guard let data = try? JSONEncoder().encode(response) else { return }
        if let json = String(bytes: data, encoding: .utf8) {
            sentRawJSON.append(json)
        }
    }

    func finish() {
        continuation.finish()
    }
}

@Suite struct AppsBridgeSessionTests {
    func makeProxy() -> AppsServerProxy {
        // 接続不要(AppsServerProxyTests と同じ理由)。displayMode テストでは呼ばれない。
        AppsServerProxy(client: Client(name: "test", version: "0"))
    }

    /// initialize→initialized を送り込んで ready まで持っていく共通 helper。
    /// `start()` してから initialize を push し、応答が sentRawJSON に積まれるのを待ってから
    /// initialized を push する(Session の受信ループは非同期なので、応答到着を軽くポーリングする)。
    func makeReadySession(
        transport: MockTransport,
        // HOLB: passthrough レーンのゲート式モックを挿すための注入点(既定は接続不要の実 proxy)。
        proxy: (any AppsServerProxying)? = nil,
        // HOLB: size-changed が View から来たとき呼ばれるコールバック(既定は無視)。
        onSizeChanged: @escaping @Sendable (Double) async -> Void = { _ in },
        // 既定 nil = 本番の「ハンドラ未注入」構成に一致(fullscreen 非広告・request-display-mode 拒否)。
        onDisplayModeRequested: (@Sendable (UIDisplayMode) async -> DisplayModeResolution)? = nil,
        // UX #1: カード capability(fullscreen 対応)を Features へ流す注入点(既定は無視)。
        onCardCapabilities: (@Sendable (_ supportsFullscreen: Bool) async -> Void)? = nil,
        // UX #1: initialize で push する appCapabilities の生 JSON(fullscreen 宣言の有無をテストで切替える)。
        appCapabilitiesJSON: String = "{}",
        // #5: 初期テーマ/スタイル(初期 hostContext に載る値を検証するため注入できるようにする)。
        theme: UITheme = .light,
        styles: HostStyles? = nil
    ) async -> AppsBridgeSession {
        let session = AppsBridgeSession(
            transport: transport,
            proxy: proxy ?? makeProxy(),
            containerWidth: 340,
            maxHeight: 600,
            theme: theme,
            styles: styles,
            onSizeChanged: onSizeChanged,
            onDisplayModeRequested: onDisplayModeRequested,
            onCardCapabilities: onCardCapabilities)
        await session.start()

        transport.push(#"""
        {"jsonrpc":"2.0","id":1,"method":"ui/initialize","params":{
          "appInfo":{"name":"test-card","version":"1"},
          "appCapabilities":\#(appCapabilitiesJSON),
          "protocolVersion":"2025-11-21"}}
        """#)
        await waitUntil { !transport.sentRawJSON.isEmpty }

        transport.push(#"{"jsonrpc":"2.0","method":"ui/notifications/initialized"}"#)
        // ready 遷移(outbox flush)は受信ループの非同期消化に依存する。Task.yield 1回では ready 到達前に
        // 次操作へ進むレースが HOLB テストの並行負荷で顕在化したので、決定的に ready を待つ(以前これで直した)。
        await waitUntil { await session.isReadyForTests }
        return session
    }

    /// 受信ループ(consumeTask)の非同期消化を待つための軽量ポーリング。CheckedContinuation を
    /// 使わないのは、テストしたい対象が「複数ステップにまたがる副作用の有無」であって
    /// 単発の応答相関ではないため(teardown の continuation とは事情が違う)。
    func waitUntil(timeout: Duration = .seconds(1), _ condition: @Sendable () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// 上の同期版の async クロージャ版オーバーロード(HOLB)。actor 隔離状態(session.isReadyForTests・
    /// SizeRecorder.count など)を await で覗きながら待つために要る。sync 版はそのまま残す
    /// (既存呼び出しは exact match で sync 版を選ぶ)。
    func waitUntil(timeout: Duration = .seconds(1), _ condition: @Sendable () async -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while await !condition(), ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - 昇格受理

    @Test("request-display-mode(fullscreen)受理: 応答は即返す・host-context-changed はここでは送らない(監査 2026-07-18 HIGH #1)")
    func requestDisplayModeAccepted() async throws {
        // 【2026-07-18 テスト改訂の背景】旧実装は Session が resolution 決定直後に応答 + 寸法通知の
        // 両方を自分で送っていた。この「resolution 後に即 host-context-changed」が、実機で
        // WKWebView の fullscreen コンテナへの reparent(SwiftUI 側の非同期処理)より先に寸法通知が
        // 届いてしまい、カードが旧コンテナ幅のまま全画面寸法でリフローする不具合の根因だった
        // (監査 2026-07-18 HIGH #1・反証検証済み)。修正で Session は「応答(結果のモード)だけ」を
        // 即返すようにし、寸法を運ぶ host-context-changed は Features 側が実際の reparent 完了を
        // 検知してから明示的に session.notifyDisplayModeChanged を呼ぶ形に一本化した
        // (InlineCardHost.notifyReparented・AppCardView.onAdopted 参照)。このテストは Session
        // 単体としての新しい契約(応答のみ即時・通知は別呼び出し)を検証する。
        let transport = MockTransport()
        let session = await makeReadySession(
            transport: transport,
            onDisplayModeRequested: { _ in DisplayModeResolution(mode: .fullscreen) })

        let beforeCount = transport.sentRawJSON.count
        transport.push(#"{"jsonrpc":"2.0","id":42,"method":"ui/request-display-mode","params":{"mode":"fullscreen"}}"#)
        await waitUntil { transport.sentRawJSON.count >= beforeCount + 1 }
        try? await Task.sleep(for: .milliseconds(30))  // host-context-changed が追い遅れで来ないことも確認する猶予。

        // 応答1本だけが送られ、host-context-changed はまだ送られていない。
        let newMessages = transport.sentRawJSON[beforeCount...]
        #expect(newMessages.count == 1)
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: Data(newMessages.first!.utf8))
        #expect(response.id == .int(42))
        #expect(response.result?["mode"] == .string("fullscreen"))

        // Features 側の reparent 完了フックに相当する明示呼び出しで、初めて host-context-changed が出る。
        let afterNotifyCount = transport.sentRawJSON.count
        await session.notifyDisplayModeChanged(
            to: .fullscreen,
            containerDimensions: ContainerDimensions(width: 390, maxHeight: 700)
        )
        let notificationMessages = transport.sentRawJSON[afterNotifyCount...]
        #expect(notificationMessages.count == 1)
        let notification = try JSONDecoder().decode(
            JSONRPCNotification.self,
            from: Data(notificationMessages.first!.utf8)
        )
        #expect(notification.method == AppsMethod.hostContextChanged)
        #expect(notification.params?["displayMode"] == .string("fullscreen"))
        #expect(notification.params?["containerDimensions"]?["width"] == .int(390))

        await session.close()
    }

    // MARK: - 昇格拒否(ハンドラ未注入 = nil)

    @Test("request-display-mode(fullscreen)拒否(ハンドラ nil): result.mode=inline のみ・host-context-changed は送出されない")
    func requestDisplayModeRejectedByDefault() async throws {
        let transport = MockTransport()
        // onDisplayModeRequested を明示注入しない = init 既定 nil(fullscreen 非広告・現状維持を返す = 拒否)。
        let session = await makeReadySession(transport: transport)

        let beforeCount = transport.sentRawJSON.count
        transport.push(#"{"jsonrpc":"2.0","id":7,"method":"ui/request-display-mode","params":{"mode":"fullscreen"}}"#)
        // 応答1本だけが来ることを確認したいので、応答到着を待ってから少し余裕を見て件数を固定する。
        await waitUntil { transport.sentRawJSON.count >= beforeCount + 1 }
        try? await Task.sleep(for: .milliseconds(30))

        let newMessages = transport.sentRawJSON[beforeCount...]
        #expect(newMessages.count == 1)
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: Data(newMessages.first!.utf8))
        #expect(response.id == .int(7))
        #expect(response.result?["mode"] == .string("inline"))

        await session.close()
    }

    // MARK: - ホスト起点の通知

    @Test("notifyDisplayModeChanged: ready なら host-context-changed が1本出る")
    func notifyDisplayModeChangedSendsNotification() async throws {
        let transport = MockTransport()
        let session = await makeReadySession(transport: transport)

        let beforeCount = transport.sentRawJSON.count
        await session.notifyDisplayModeChanged(to: .fullscreen)

        let newMessages = transport.sentRawJSON[beforeCount...]
        #expect(newMessages.count == 1)
        let notification = try JSONDecoder().decode(JSONRPCNotification.self, from: Data(newMessages.first!.utf8))
        #expect(notification.method == AppsMethod.hostContextChanged)
        #expect(notification.params?["displayMode"] == .string("fullscreen"))
        #expect(notification.params?["containerDimensions"]?["maxHeight"] == .int(600))

        await session.close()
    }

    // MARK: - テーマ / スタイル(#5 ダークモード・apps.mdx:822-882)

    @Test("initialize 応答の hostContext に注入した theme/styles が載る")
    func initializeCarriesThemeAndStyles() async throws {
        let transport = MockTransport()
        let styles = HostStyles(variables: [
            UIStyleVariableKey.colorBackgroundPrimary: "rgba(0, 0, 0, 1.000)",
            UIStyleVariableKey.colorTextPrimary: "rgba(255, 255, 255, 1.000)"
        ])
        let session = await makeReadySession(transport: transport, theme: .dark, styles: styles)

        // sentRawJSON の先頭 = initialize 応答(makeReadySession が最初に待つのがこれ)。
        let response = try JSONDecoder().decode(
            JSONRPCResponse.self, from: Data(try #require(transport.sentRawJSON.first).utf8))
        let result = try #require(response.result).decode(InitializeResult.self)
        #expect(result.hostContext.theme == .dark)
        #expect(result.hostContext.styles == styles)

        await session.close()
    }

    @Test("notifyThemeChanged: ready なら theme/styles だけ載せた host-context-changed が1本出る")
    func notifyThemeChangedSendsPartialContext() async throws {
        let transport = MockTransport()
        let session = await makeReadySession(transport: transport, theme: .light)

        let beforeCount = transport.sentRawJSON.count
        let dark = HostStyles(variables: [UIStyleVariableKey.colorBackgroundPrimary: "rgba(0, 0, 0, 1.000)"])
        await session.notifyThemeChanged(theme: .dark, styles: dark)

        let newMessages = transport.sentRawJSON[beforeCount...]
        #expect(newMessages.count == 1)
        let notification = try JSONDecoder().decode(JSONRPCNotification.self, from: Data(newMessages.first!.utf8))
        #expect(notification.method == AppsMethod.hostContextChanged)
        #expect(notification.params?["theme"] == .string("dark"))
        // 部分更新: 変えていない displayMode/containerDimensions は載せない(spec の Partial context)。
        #expect(notification.params?["displayMode"] == nil)
        #expect(notification.params?["containerDimensions"] == nil)
        // styles.variables のトークンがそのまま届く。
        #expect(notification.params?["styles"]?["variables"]?[UIStyleVariableKey.colorBackgroundPrimary]
            == .string("rgba(0, 0, 0, 1.000)"))

        await session.close()
    }

    // MARK: - availableDisplayModes 広告のハンドラ分岐(H4-F・死にボタン排除)

    /// initialize 応答の hostContext.availableDisplayModes を取り出す(sentRawJSON の先頭 = initialize 応答)。
    func advertisedModes(_ transport: MockTransport) throws -> [UIDisplayMode] {
        let response = try JSONDecoder().decode(
            JSONRPCResponse.self,
            from: Data(try #require(transport.sentRawJSON.first).utf8)
        )
        let result = try #require(response.result).decode(InitializeResult.self)
        return try #require(result.hostContext.availableDisplayModes)
    }

    @Test("ハンドラ未注入(nil): availableDisplayModes は [inline] のみ(fullscreen を広告しない=死にボタン排除)")
    func advertisesInlineOnlyWithoutHandler() async throws {
        let transport = MockTransport()
        let session = await makeReadySession(transport: transport)   // 既定 nil ハンドラ
        #expect(try advertisedModes(transport) == [.inline])
        await session.close()
    }

    @Test("ハンドラ注入時: availableDisplayModes は [inline, fullscreen](昇格できる ⇔ 広告する を一致させる)")
    func advertisesFullscreenWithHandler() async throws {
        let transport = MockTransport()
        let session = await makeReadySession(
            transport: transport,
            onDisplayModeRequested: { _ in DisplayModeResolution(mode: .inline) })
        #expect(try advertisedModes(transport) == [.inline, .fullscreen])
        await session.close()
    }
}

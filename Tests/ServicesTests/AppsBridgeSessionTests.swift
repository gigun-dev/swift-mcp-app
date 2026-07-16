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
private final class MockTransport: AppsBridgeTransport, @unchecked Sendable {
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
        sentRawJSON.append(String(decoding: data, as: UTF8.self))
    }

    func finish() {
        continuation.finish()
    }
}

@Suite struct AppsBridgeSessionTests {
    private func makeProxy() -> AppsServerProxy {
        // 接続不要(AppsServerProxyTests と同じ理由)。displayMode テストでは呼ばれない。
        AppsServerProxy(client: Client(name: "test", version: "0"))
    }

    /// initialize→initialized を送り込んで ready まで持っていく共通 helper。
    /// `start()` してから initialize を push し、応答が sentRawJSON に積まれるのを待ってから
    /// initialized を push する(Session の受信ループは非同期なので、応答到着を軽くポーリングする)。
    private func makeReadySession(
        transport: MockTransport,
        onDisplayModeRequested: @escaping @Sendable (UIDisplayMode) async -> DisplayModeResolution
            = { _ in DisplayModeResolution(mode: .inline) }
    ) async -> AppsBridgeSession {
        let session = AppsBridgeSession(
            transport: transport,
            proxy: makeProxy(),
            containerWidth: 340,
            maxHeight: 600,
            onDisplayModeRequested: onDisplayModeRequested)
        await session.start()

        transport.push(#"""
        {"jsonrpc":"2.0","id":1,"method":"ui/initialize","params":{
          "appInfo":{"name":"test-card","version":"1"},
          "appCapabilities":{},
          "protocolVersion":"2025-11-21"}}
        """#)
        await waitUntil { !transport.sentRawJSON.isEmpty }

        transport.push(#"{"jsonrpc":"2.0","method":"ui/notifications/initialized"}"#)
        // ready 遷移(outbox flush)が非同期なので一呼吸置く。以後のテストは ready 前提で push する。
        await Task.yield()
        return session
    }

    /// 受信ループ(consumeTask)の非同期消化を待つための軽量ポーリング。CheckedContinuation を
    /// 使わないのは、テストしたい対象が「複数ステップにまたがる副作用の有無」であって
    /// 単発の応答相関ではないため(teardown の continuation とは事情が違う)。
    private func waitUntil(timeout: Duration = .seconds(1), _ condition: @Sendable () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - 昇格受理

    @Test("request-display-mode(fullscreen)受理: result.mode=fullscreen 応答 → host-context-changed 通知の順")
    func requestDisplayModeAccepted() async throws {
        let transport = MockTransport()
        let session = await makeReadySession(
            transport: transport,
            onDisplayModeRequested: { _ in DisplayModeResolution(mode: .fullscreen) })

        let beforeCount = transport.sentRawJSON.count
        transport.push(#"{"jsonrpc":"2.0","id":42,"method":"ui/request-display-mode","params":{"mode":"fullscreen"}}"#)
        await waitUntil { transport.sentRawJSON.count >= beforeCount + 2 }

        let newMessages = transport.sentRawJSON[beforeCount...]
        #expect(newMessages.count == 2)

        // (a) 応答が先: result.mode == "fullscreen"。
        let responseJSON = newMessages[newMessages.startIndex]
        let response = try JSONDecoder().decode(JSONRPCResponse.self, from: Data(responseJSON.utf8))
        #expect(response.id == .int(42))
        #expect(response.result?["mode"] == .string("fullscreen"))

        // (b) その後 host-context-changed が displayMode:fullscreen + 寸法つきで送出される。
        let notificationJSON = newMessages[newMessages.startIndex + 1]
        let notification = try JSONDecoder().decode(JSONRPCNotification.self, from: Data(notificationJSON.utf8))
        #expect(notification.method == AppsMethod.hostContextChanged)
        #expect(notification.params?["displayMode"] == .string("fullscreen"))
        #expect(notification.params?["containerDimensions"]?["width"] == .int(340))

        await session.close()
    }

    // MARK: - 昇格拒否(既定コールバック)

    @Test("request-display-mode(fullscreen)拒否(既定 = inline): result.mode=inline のみ・host-context-changed は送出されない")
    func requestDisplayModeRejectedByDefault() async throws {
        let transport = MockTransport()
        // onDisplayModeRequested を明示注入しない = init 既定(常に inline を返す = 拒否)。
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
}

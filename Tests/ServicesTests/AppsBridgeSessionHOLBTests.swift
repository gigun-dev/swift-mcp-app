// passthrough往復が通知や別requestを塞がないHOL blocking回避とclose時の配送停止を検証する。
// 共通bridge fixtureを再利用しつつ、並行処理固有の責務として分割する。
import Foundation
import Testing
import MCP

@testable import Kernel
@testable import Services

extension AppsBridgeSessionTests {
    // MARK: - HOLB(head-of-line blocking の解消)

    /// passthrough(tools/call)の実往復を手動開放の CheckedContinuation でゲートするモック proxy。
    /// sleep で待つのではなく、テストが `open(_:result:)` を呼ぶまで往復を止める(決定的)。
    /// 呼び出しは params.arguments.k をキーに識別する(複数 in-flight を別々に開放するため)。
    private actor GatedMockProxy: AppsServerProxying {
        private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
        private var opened: [String: JSONValue] = [:]

        /// キーの往復が現在ゲートで停止中か(テストの観測用)。
        func isWaiting(_ key: String) -> Bool { waiters[key] != nil }

        func passthroughToolsCall(params: JSONValue?) async throws -> JSONValue {
            let key = params?["arguments"]?["k"]?.stringValue ?? "default"
            await gate(key)
            // open で渡された結果を id 相関確認用に返す(なければ最小の object)。
            return opened[key] ?? .object(["ok": .bool(true)])
        }

        func passthroughResourcesRead(params: JSONValue?) async throws -> JSONValue {
            .object([:])
        }

        private func gate(_ key: String) async {
            if opened[key] != nil { return }   // 既に開放済みなら止めない。
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                waiters[key] = continuation
            }
        }

        /// ゲートを開けて往復を先へ進める。result は passthroughToolsCall の戻り値になる。
        func open(_ key: String, result: JSONValue) {
            opened[key] = result
            if let continuation = waiters.removeValue(forKey: key) { continuation.resume() }
        }
    }

    /// onSizeChanged の呼び出しを記録する actor(応答との順序を決定的に観測する)。
    private actor SizeRecorder {
        private(set) var heights: [Double] = []
        func record(_ height: Double) { heights.append(height) }
        var count: Int { heights.count }
    }

    private actor CompletionRecorder {
        private(set) var values: [Bool] = []
        func record(_ value: Bool) { values.append(value) }
    }

    @Test("HOLB①: ゲート停止中の tools/call を追い越して size-changed が応答より先に処理される")
    func sizeChangedNotBlockedByInflightToolsCall() async throws {
        let transport = MockTransport()
        let proxy = GatedMockProxy()
        let recorder = SizeRecorder()
        let session = await makeReadySession(
            transport: transport, proxy: proxy,
            onSizeChanged: { await recorder.record($0) })

        let beforeCount = transport.sentRawJSON.count
        // tools/call を push(proxy 往復がゲートで停止)。
        transport.push(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"x","arguments":{"k":"slow"}}}"#)
        // 続けて size-changed を push。直列実装だと tools/call の往復完了まで詰まる。
        transport.push(#"{"jsonrpc":"2.0","method":"ui/notifications/size-changed","params":{"height":222}}"#)

        // 応答より前に onSizeChanged が呼ばれる(HOLB 解消の中核)。
        await waitUntil { await recorder.count >= 1 }
        #expect(await recorder.heights == [222])
        // この時点で tools/call 応答はまだ配送されていない。
        #expect(transport.sentRawJSON.count == beforeCount)

        // ゲート開放 → id 相関した応答が配送される。
        await proxy.open("slow", result: .object(["ok": .bool(true)]))
        await waitUntil { transport.sentRawJSON.count > beforeCount }
        let response = try JSONDecoder().decode(
            JSONRPCResponse.self, from: Data(transport.sentRawJSON.last!.utf8))
        #expect(response.id == .int(1))
        #expect(response.result?["ok"] == .bool(true))

        await session.close()
    }

    @Test("HOLB②: 複数 in-flight — 速い tools/call(id=2)が遅い(id=1)より先に応答・両者 id 相関が正")
    func multipleInflightRespondOutOfOrder() async throws {
        let transport = MockTransport()
        let proxy = GatedMockProxy()
        let session = await makeReadySession(transport: transport, proxy: proxy)

        let beforeCount = transport.sentRawJSON.count
        transport.push(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"slow","arguments":{"k":"slow"}}}"#)
        transport.push(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"fast","arguments":{"k":"fast"}}}"#)
        // 両方の往復がゲートに到達するのを待つ(非直列に両方 in-flight)。
        // && の右辺は非 async autoclosure になり await を通せないので、2つの await を別々に評価して畳む。
        await waitUntil {
            let slow = await proxy.isWaiting("slow")
            let fast = await proxy.isWaiting("fast")
            return slow && fast
        }

        // 速い方(id=2)を先に開放 → 先に応答が来る。
        await proxy.open("fast", result: .object(["r": .int(2)]))
        await waitUntil { transport.sentRawJSON.count >= beforeCount + 1 }
        let first = try JSONDecoder().decode(
            JSONRPCResponse.self, from: Data(transport.sentRawJSON.last!.utf8))
        #expect(first.id == .int(2))
        #expect(first.result?["r"] == .int(2))

        // 遅い方(id=1)を後で開放。
        await proxy.open("slow", result: .object(["r": .int(1)]))
        await waitUntil { transport.sentRawJSON.count >= beforeCount + 2 }
        let second = try JSONDecoder().decode(
            JSONRPCResponse.self, from: Data(transport.sentRawJSON.last!.utf8))
        #expect(second.id == .int(1))
        #expect(second.result?["r"] == .int(1))

        await session.close()
    }

    @Test("HOLB③(S2): ゲート停止中に close → 開放後も応答は配送されない")
    func closedSessionDropsInflightResponse() async throws {
        let transport = MockTransport()
        let proxy = GatedMockProxy()
        let session = await makeReadySession(transport: transport, proxy: proxy)

        transport.push(#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"x","arguments":{"k":"slow"}}}"#)
        await waitUntil { await proxy.isWaiting("slow") }

        // ゲート閉のまま close(webView 破棄相当)。
        await session.close()
        let afterClose = transport.sentRawJSON.count

        // 開放しても、proxyRequest の closed ガードで応答は握り潰される。
        await proxy.open("slow", result: .object(["ok": .bool(true)]))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(transport.sentRawJSON.count == afterClose)
    }

    @Test("tools/call完了callbackはCallToolResult.isError=trueを成功扱いしない")
    func toolCallCompletionRejectsMCPErrorResult() async {
        let transport = MockTransport()
        let proxy = GatedMockProxy()
        let recorder = CompletionRecorder()
        let session = await makeReadySession(
            transport: transport,
            proxy: proxy,
            onCardToolCallCompleted: { await recorder.record($0) }
        )

        transport.push(
            #"{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"refresh","arguments":{"k":"error"}}}"#
        )
        await waitUntil { await proxy.isWaiting("error") }
        await proxy.open("error", result: .object(["isError": .bool(true)]))
        await waitUntil { await recorder.values.count == 1 }

        #expect(await recorder.values == [false])
        await session.close()
    }

    @Test("観測arm前に開始したtools/callの遅着完了はcallbackへ流さない")
    func toolCallStartedBeforeObservationIsIgnored() async {
        let transport = MockTransport()
        let proxy = GatedMockProxy()
        let recorder = CompletionRecorder()
        let session = await makeReadySession(
            transport: transport,
            proxy: proxy,
            shouldObserveCardToolCall: { false },
            onCardToolCallCompleted: { await recorder.record($0) }
        )

        transport.push(
            #"{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"early","arguments":{"k":"early"}}}"#
        )
        await waitUntil { await proxy.isWaiting("early") }
        await proxy.open("early", result: .object(["isError": .bool(false)]))
        try? await Task.sleep(for: .milliseconds(30))

        #expect(await recorder.values.isEmpty)
        await session.close()
    }
}

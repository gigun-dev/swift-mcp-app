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

    // 【2026-07-23・queue 2】ここにあった「tools/call 完了 callback の isError 判定」「観測 arm 前の遅着
    // 完了は流さない」の2テストは撤去した。履歴 revalidation gate が消え、完了観測フック
    // (shouldObserveCardToolCall / onCardToolCallCompleted)自体が無くなったため。撤去理由は caldav 側
    // 裁定(caldavリポジトリ docs/modeling/15・SWR)。鮮度は caldav 側 SWR が担い、その発火条件である
    // 「履歴復元時の toolResult 再 push」は下の historyRestorePushesSavedToolResult で固定する。

    @Test("履歴復元: 保存済みtoolResult(structuredContent)がtool-input→tool-resultの順でカードへ再pushされる")
    func historyRestorePushesSavedToolResult() async throws {
        // caldav 側 SWR(generatedAt 60 秒判定)の唯一の発火条件は「host が履歴復元時に保存済み
        // toolResult をカードへ再 push すること」。gate 撤去後もこの再 push だけは必ず残す
        // (InlineCardHost.sendInitialPayload が担う)。ここでは Session 層の配送順序として固定し、
        // 履歴経路が tool-input → tool-result(保存 structuredContent)を欠かさず送ることを保証する。
        let transport = MockTransport()
        let session = await makeReadySession(transport: transport)

        let beforeCount = transport.sentRawJSON.count
        // 履歴復元で保存済み arguments と structuredContent を再送する(sendInitialPayload と同順)。
        let savedArguments: JSONValue = .object(["listId": .string("today")])
        let savedResult: JSONValue = .object([
            "structuredContent": .object([
                "tasks": .array([.string("a")]),
                // caldav SWR はこの generatedAt を見て 60 秒判定する(host は値を解釈しない・中立)。
                "generatedAt": .string("2026-07-23T00:00:00Z")
            ])
        ])
        await session.sendToolInput(arguments: savedArguments)
        await session.sendToolResult(savedResult)

        // ready 済みなので即送信される。tool-input が先、tool-result が後の順序を固定する。
        await waitUntil { transport.sentRawJSON.count >= beforeCount + 2 }
        let sent = Array(transport.sentRawJSON.suffix(2))
        let inputNote = try JSONDecoder().decode(JSONRPCNotification.self, from: Data(sent[0].utf8))
        let resultNote = try JSONDecoder().decode(JSONRPCNotification.self, from: Data(sent[1].utf8))

        #expect(inputNote.method == "ui/notifications/tool-input")
        #expect(inputNote.params?["arguments"] == savedArguments)
        #expect(resultNote.method == "ui/notifications/tool-result")
        // 保存 structuredContent が改変されず(hint marking も無く)そのまま再 push される。
        #expect(resultNote.params == savedResult)

        await session.close()
    }
}

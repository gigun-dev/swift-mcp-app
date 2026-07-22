// MultiServerToolExecutor(M2・複数サーバー同時接続のルーティング)のテスト。
// 前置ツール名 `slug__tool` を正しい実行口へ振り分け、元ツール名で委譲することを固定する。
// swift-sdk・ネットワークは使わず、記録するだけのスタブ executor を差し替える。
import Foundation
import Testing
import Kernel
@testable import Services

/// 呼ばれた name/arguments を記録し、決め打ちの JSONValue を返すスタブ実行口(actor で Sendable)。
private actor RecordingExecutor: MCPToolExecuting {
    private(set) var calls: [(name: String, arguments: JSONValue?)] = []
    let returnValue: JSONValue

    init(returnValue: JSONValue) { self.returnValue = returnValue }

    func callTool(name: String, arguments: JSONValue?) async throws -> JSONValue {
        calls.append((name, arguments))
        return returnValue
    }

    func recorded() -> [(name: String, arguments: JSONValue?)] { calls }
}

@Suite struct MultiServerToolExecutorTests {
    @Test("前置名を slug で振り分け、元ツール名で該当 executor に委譲する")
    func routesToCorrectServer() async throws {
        let caldav = RecordingExecutor(returnValue: .string("caldav-result"))
        let other = RecordingExecutor(returnValue: .string("other-result"))
        let exec = MultiServerToolExecutor(executors: ["caldav": caldav, "other": other])

        let result = try await exec.callTool(name: "caldav__list-todos", arguments: .object(["a": .string("b")]))
        #expect(result == .string("caldav-result"))

        // 元ツール名(前置なし)で委譲されている。
        let caldavCalls = await caldav.recorded()
        #expect(caldavCalls.count == 1)
        #expect(caldavCalls[0].name == "list-todos")
        // 別サーバーは呼ばれていない。
        let otherCalls = await other.recorded()
        #expect(otherCalls.isEmpty)
    }

    @Test("前置のない名前は unknownPrefix で throw する")
    func throwsOnUnprefixed() async {
        let exec = MultiServerToolExecutor(executors: ["caldav": RecordingExecutor(returnValue: .null)])
        await #expect(throws: MultiServerToolError.self) {
            try await exec.callTool(name: "list-todos", arguments: nil)
        }
    }

    @Test("未知の slug は unknownServer で throw する")
    func throwsOnUnknownServer() async {
        let exec = MultiServerToolExecutor(executors: ["caldav": RecordingExecutor(returnValue: .null)])
        await #expect(throws: MultiServerToolError.self) {
            try await exec.callTool(name: "ghost__do-thing", arguments: nil)
        }
    }

    @Test("短縮wire名は明示routeで元の長いツール名へ戻して委譲する")
    func routesShortenedWireName() async throws {
        let recorder = RecordingExecutor(returnValue: .string("ok"))
        let original = "operation-" + String(repeating: "x", count: 100)
        let route = ToolNamespacing.route(slug: "server", tool: original)
        let exec = MultiServerToolExecutor(executors: ["server": recorder], routes: [route])

        #expect(route.wireName.count == 64)
        _ = try await exec.callTool(name: route.wireName, arguments: nil)
        #expect(await recorder.recorded().first?.name == original)
    }

    @Test("異なるrouteが同一wire名へ衝突した場合は後勝ちにせず拒否する")
    func rejectsAmbiguousExplicitRoute() async {
        let recorder = RecordingExecutor(returnValue: .null)
        let routes = [
            ToolRoute(wireName: "same", slug: "a", toolName: "first"),
            ToolRoute(wireName: "same", slug: "b", toolName: "second")
        ]
        let exec = MultiServerToolExecutor(executors: ["a": recorder, "b": recorder], routes: routes)

        await #expect(throws: MultiServerToolError.self) {
            try await exec.callTool(name: "same", arguments: nil)
        }
        #expect(await recorder.recorded().isEmpty)
    }
}

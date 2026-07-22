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

        let r = try await exec.callTool(name: "caldav__list-todos", arguments: .object(["a": .string("b")]))
        #expect(r == .string("caldav-result"))

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
}

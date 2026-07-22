// tool-use ループ(ChatViewModel・T3)の単体テスト。設計 §3。
//
// ネットワーク・swift-sdk・OAuth 一切なしで回す(指示 C): スタブ LLMClient(呼ばれた回数で
// 異なる scripted レスポンスを返す)+ スタブ MCPToolExecuting(name/arguments を記録し決め打ちの
// JSONValue を返す or throw)を注入して、ループの分岐(テキストのみ / 単一 tool_call /
// 複数 tool_call / 最大反復ガード / ツール失敗継続)を固定する。
//
// テストは @MainActor(ChatViewModel が @MainActor のため)。
import Foundation
import Testing

@testable import Kernel
@testable import Services

// MARK: - スタブ

/// scripted な LLMClient。stream(_:) が呼ばれるたびに次の台本イベント列を流す。
/// 呼び出しごとに送られた request を records に残し、履歴(messages)を検証できるようにする。
///
/// final class + @unchecked Sendable: LLMClient は Sendable 要求。可変状態(callCount・records)は
/// テスト内で **ChatViewModel(@MainActor)から直列に**しか触られない(send は1本ずつ await する・
/// 並行実行するのはツール実行であって LLM stream ではない)ため、ロックなしで安全。
final class ScriptedLLMClient: LLMClient, @unchecked Sendable {
    /// 1回の stream 呼び出しで流すイベント列(末尾は必ず .completed)。
    let scripts: [[LLMEvent]]
    private(set) var callCount = 0
    private(set) var receivedRequests: [ChatCompletionRequest] = []

    init(scripts: [[LLMEvent]]) {
        self.scripts = scripts
    }

    func stream(_ request: ChatCompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        // 何回目の呼び出しかで台本を選ぶ。台本を超えて呼ばれたら最後の台本を使い回す
        // (最大反復ガードのテストで「毎回 .toolCalls」を1本の台本で表現できるように)。
        let index = min(callCount, scripts.count - 1)
        let events = scripts[index]
        receivedRequests.append(request)
        callCount += 1
        return AsyncThrowingStream { continuation in
            for event in events { continuation.yield(event) }
            continuation.finish()
        }
    }
}

/// スタブ MCP ツール実行口。呼ばれた (name, arguments) を記録し、決め打ちの結果を返す。
/// shouldThrow=true のツール名は throw して「ツール失敗でループ継続」を検証する。
///
/// actor: MCPToolExecuting は Sendable かつ並行実行(TaskGroup)されるため、記録配列への
/// 追記を直列化する必要がある。actor で自明に満たす。
actor StubToolExecutor: MCPToolExecuting {
    struct Call: Sendable, Equatable {
        let name: String
        let arguments: JSONValue?
    }
    private(set) var calls: [Call] = []
    /// name → 返す結果。無ければ .null を返す。
    let results: [String: JSONValue]
    /// この name が呼ばれたら throw する集合。
    let throwing: Set<String>

    init(results: [String: JSONValue] = [:], throwing: Set<String> = []) {
        self.results = results
        self.throwing = throwing
    }

    func callTool(name: String, arguments: JSONValue?) async throws -> JSONValue {
        calls.append(Call(name: name, arguments: arguments))
        if throwing.contains(name) {
            throw StubError.boom
        }
        return results[name] ?? .null
    }

    enum StubError: Error { case boom }
}

// MARK: - テスト

// .serialized の理由(2026-07-16): このスイートを並列実行すると、全テスト pass 後の
// **プロセス teardown で swift-testing ランナーが signal 11(SIGSEGV)**する現象が出た
// (Swift 6.3 / macOS 26)。ChatModel の ToolCallStep に resultJSON フィールドを足した
// タイミングで決定的に再現するようになった(バイナリのレイアウト変化が並列 teardown の
// 競合を顕在化させたと見られる — テスト自体はすべて成功しており、我々のロジックの不具合
// ではない。切り分け: field 有無で crash が入れ替わる/Kernel 単独は無事/このスイートを
// .serialized にすると消える、を確認済み)。並列にする利得より make check の安定を優先し、
// このスイートは直列実行にする(ChatViewModel は元々 @MainActor で直列に叩く前提でもある)。
@MainActor
@Suite(.serialized) struct ChatViewModelTests {
    // 共通の tool_call 生成ヘルパ(arguments は JSON 文字列)。
    func toolCall(id: String, name: String, arguments: String) -> ToolCall {
        ToolCall(id: id, function: .init(name: name, arguments: arguments))
    }

    func usage(_ promptTokens: Int, _ completionTokens: Int) -> Usage {
        Usage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: promptTokens + completionTokens
        )
    }

    // 1) テキストのみ: 1反復で終了・textDelta 連結・usage 計上。
    @Test func テキストのみで1反復終了しusage計上() async {
        let llm = ScriptedLLMClient(scripts: [[
            .textDelta("こんに"),
            .textDelta("ちは"),
            .completed(.stop, [], usage(10, 5))
        ]])
        let executor = StubToolExecutor()
        let viewModel = ChatViewModel(llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil)

        await viewModel.send("やあ")

        #expect(llm.callCount == 1)
        #expect(viewModel.isRunning == false)
        #expect(viewModel.errorMessage == nil)
        // 表示: user ターン + assistant ターン。
        #expect(viewModel.turns.count == 2)
        #expect(viewModel.turns[0].role == .user)
        #expect(viewModel.turns[1].role == .assistant)
        #expect(viewModel.turns[1].text == "こんにちは")
        #expect(viewModel.turns[1].usage == usage(10, 5))
        #expect(viewModel.lastUsage == usage(10, 5))
        #expect(viewModel.cumulativeUsage == usage(10, 5))
        // ツールは呼ばれない。
        #expect(await executor.calls.isEmpty)
    }

    // 2) 単一 tool_call → executor が結果を返す → 2周目で .stop。role:tool が積まれ最終テキストが出る。
    @Test func 単一toolCallで2周して確定() async {
        let llm = ScriptedLLMClient(scripts: [
            // 1周目: ツールを呼ぶ。
            [.completed(
                .toolCalls,
                [toolCall(id: "c1", name: "get_weather", arguments: "{\"city\":\"Tokyo\"}")],
                usage(20, 3)
            )],
            // 2周目: ツール結果を見て回答。
            [.textDelta("東京は晴れ"), .completed(.stop, [], usage(30, 8))]
        ])
        let executor = StubToolExecutor(results: ["get_weather": .object(["temp": .int(30)])])
        let viewModel = ChatViewModel(llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil)

        await viewModel.send("東京の天気は?")

        #expect(llm.callCount == 2)
        #expect(viewModel.errorMessage == nil)
        // executor が正しい name/arguments で呼ばれた。
        let calls = await executor.calls
        #expect(calls.count == 1)
        #expect(calls[0].name == "get_weather")
        #expect(calls[0].arguments == .object(["city": .string("Tokyo")]))
        // 最終 assistant テキスト。
        #expect(viewModel.turns.last?.text == "東京は晴れ")
        // usage は2ターンぶん累計。
        #expect(viewModel.cumulativeUsage == usage(50, 11))
        #expect(viewModel.lastUsage == usage(30, 8))
        // 2周目のリクエストには role:tool メッセージが含まれる(wire に積まれた証拠)。
        let secondReq = llm.receivedRequests[1]
        #expect(secondReq.messages.contains {
            $0.role == .tool && $0.toolCallId == "c1" && $0.name == "get_weather"
        })
        // assistant の tool_calls メッセージもペアで含まれる。
        #expect(secondReq.messages.contains { $0.role == .assistant && ($0.toolCalls?.isEmpty == false) })
    }

    // 3) 複数 tool_call(1ターンで2件)→ 両方実行・role:tool が2件・順序安定(id 昇順)。
    @Test func 複数toolCallは両方実行されrole_tool2件が安定順序() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.toolCalls, [
                // わざと id 降順で並べ、wire では昇順(c_a, c_b)に安定化されることを見る。
                toolCall(id: "c_b", name: "toolB", arguments: "{}"),
                toolCall(id: "c_a", name: "toolA", arguments: "{\"x\":1}")
            ], usage(20, 4))],
            [.textDelta("完了"), .completed(.stop, [], usage(25, 2))]
        ])
        let executor = StubToolExecutor(results: ["toolA": .string("A"), "toolB": .string("B")])
        let viewModel = ChatViewModel(llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil)

        await viewModel.send("両方やって")

        // 両方実行。
        let calls = await executor.calls
        #expect(Set(calls.map(\.name)) == ["toolA", "toolB"])
        // 2周目リクエストの role:tool 部分を抜き出し、tool_call_id 昇順で並んでいることを確認。
        let toolMsgs = llm.receivedRequests[1].messages.filter { $0.role == .tool }
        #expect(toolMsgs.count == 2)
        #expect(toolMsgs.map(\.toolCallId) == ["c_a", "c_b"])
        // 表示ステップは call 順(toolB, toolA)で2件・両方 done。
        let steps = viewModel.turns.first(where: { !$0.toolSteps.isEmpty })?.toolSteps ?? []
        #expect(steps.map(\.toolName) == ["toolB", "toolA"])
        #expect(steps.allSatisfy { $0.state == .done })
    }

    // 4) 最大反復ガード: 毎回 .toolCalls を返し続ける → maxIterations で打ち切りエラー。
    @Test func 最大反復で打ち切りエラー() async {
        let llm = ScriptedLLMClient(scripts: [
            // 台本は1本。ScriptedLLMClient は台本を超えたら最後を使い回すので毎回これが返る。
            [.completed(.toolCalls, [toolCall(id: "loop", name: "spin", arguments: "{}")], usage(1, 1))]
        ])
        let executor = StubToolExecutor(results: ["spin": .null])
        let viewModel = ChatViewModel(
            llm: llm,
            toolExecutor: executor,
            tools: [],
            model: "m",
            systemPrompt: nil,
            maxIterations: 3
        )

        await viewModel.send("回り続けて")

        #expect(llm.callCount == 3)
        #expect(viewModel.errorMessage != nil)
        #expect(viewModel.isRunning == false)
    }

    // 5) ツール実行 throw → 該当ステップ failed・role:tool に error・ループ継続で次の補完へ。
    @Test func ツール失敗でも継続し次補完へ() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.toolCalls, [toolCall(id: "e1", name: "flaky", arguments: "{}")], usage(5, 1))],
            [.textDelta("失敗したので別の方法を試します"), .completed(.stop, [], usage(6, 2))]
        ])
        let executor = StubToolExecutor(throwing: ["flaky"])
        let viewModel = ChatViewModel(llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil)

        await viewModel.send("flaky を呼んで")

        // ループは継続して2周目まで回った(= 打ち切りエラーではない)。
        #expect(llm.callCount == 2)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.turns.last?.text == "失敗したので別の方法を試します")
        // 該当ステップが failed。
        let steps = viewModel.turns.first(where: { !$0.toolSteps.isEmpty })?.toolSteps ?? []
        #expect(steps.count == 1)
        #expect(steps[0].state == .failed)
        // 2周目リクエストの role:tool にエラー文言が載っている。
        let toolMsg = llm.receivedRequests[1].messages.first { $0.role == .tool }
        #expect(toolMsg?.content?.contains("エラー") == true)
    }

    // 6) UI 資源を持つツールが成功 → そのターンの cards に CardEmbed が1件・structuredContent と
    //    arguments が入る(設計 §4・二重配布の (b))。role:tool の JSON 配布も従来どおり維持される。
    @Test func systemプロンプトが毎リクエスト先頭に載る() async {
        let llm = ScriptedLLMClient(scripts: [[.completed(.stop, [], nil)]])
        let viewModel = ChatViewModel(
            llm: llm,
            toolExecutor: StubToolExecutor(),
            tools: [],
            model: "m",
            systemPrompt: "あなたは助手"
        )

        await viewModel.send("hi")

        let msgs = llm.receivedRequests[0].messages
        #expect(msgs.first?.role == .system)
        #expect(msgs.first?.content == "あなたは助手")
    }
}

/// 常に stream 開始直後に throw するスタブ LLMClient(onTurnSettled のストリーム失敗経路テスト用)。
final class ThrowingLLMClient: LLMClient, @unchecked Sendable {
    func stream(_ request: ChatCompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ThrowingLLMClientError.boom)
        }
    }
    enum ThrowingLLMClientError: Error { case boom }
}

/// 「呼ばれたらずっと完了しない(長く sleep する)」スタブ LLMClient(監査 2026-07-18 MEDIUM の
/// cancel テスト用)。OpenAICompatClient.stream(_:) と同じ構造(内部 Task を onTermination で
/// cancel する)を踏襲することで、「消費側 Task のキャンセルが AsyncThrowingStream の for-await を
/// 実際に打ち切る」という本番と同じ経路をスタブでも再現する(ScriptedLLMClient は同期的に
/// 完了してしまうためこの経路を検証できない)。
final class DelayedLLMClient: LLMClient, @unchecked Sendable {
    func stream(_ request: ChatCompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // テストのタイムアウトより十分長い(cancel が来なければテストは確実に落ちる=
                    // 「キャンセルが伝播しない」というレグレッションを検出できる)。
                    try await Task.sleep(for: .seconds(10))
                    continuation.yield(.completed(.stop, [], nil))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// emit された ChatTraceEvent を記録するスタブ TraceSink。
///
/// **actor でなく NSLock で直列化する判断(設計に無い・こう解釈)**: TraceSink.emit は
/// プロトコル定義上「同期メソッド」(fire-and-forget の契約)。actor にすると emit 内部で
/// `Task { await ... }` を挟むことになり、テスト側の `await viewModel.send(...)` 完了時点で
/// 記録がすべて反映されている保証が無くなる(Task のスケジューリング次第で flaky になりうる)。
/// NSLock なら emit 呼び出しの中で同期的に配列へ追記できるので、send() が返った時点で
/// 記録は必ず確定している——tool 呼び出しは TaskGroup で並行実行される(ChatViewModel.runToolCalls)
/// ため、複数スレッドからの同時 emit に対する排他が必要でここで担保する。
final class SpyTraceSink: TraceSink, @unchecked Sendable {
    private var events: [ChatTraceEvent] = []
    private let lock = NSLock()

    func emit(_ event: ChatTraceEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    func kinds() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events.map { event in
            switch event {
            case .turnStarted: return "turnStarted"
            case .llmCompleted: return "llmCompleted"
            case .toolCallStarted: return "toolCallStarted"
            case .toolCallFinished: return "toolCallFinished"
            case .turnSettled: return "turnSettled"
            }
        }
    }

    func turnIds() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return events.map { event in
            switch event {
            case .turnStarted(_, let turnId, _): return turnId
            case .llmCompleted(let turnId, _, _): return turnId
            case .toolCallStarted(let turnId, _, _, _): return turnId
            case .toolCallFinished(let turnId, _, _, _, _): return turnId
            case .turnSettled(let turnId, _, _): return turnId
            }
        }
    }

    var eventsSnapshot: [ChatTraceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

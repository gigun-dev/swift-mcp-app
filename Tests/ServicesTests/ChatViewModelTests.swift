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

@MainActor
@Suite struct ChatViewModelTests {
    // 共通の tool_call 生成ヘルパ(arguments は JSON 文字列)。
    private func toolCall(id: String, name: String, arguments: String) -> ToolCall {
        ToolCall(id: id, function: .init(name: name, arguments: arguments))
    }

    private func usage(_ p: Int, _ c: Int) -> Usage {
        Usage(promptTokens: p, completionTokens: c, totalTokens: p + c)
    }

    // 1) テキストのみ: 1反復で終了・textDelta 連結・usage 計上。
    @Test func テキストのみで1反復終了しusage計上() async {
        let llm = ScriptedLLMClient(scripts: [[
            .textDelta("こんに"),
            .textDelta("ちは"),
            .completed(.stop, [], usage(10, 5)),
        ]])
        let executor = StubToolExecutor()
        let vm = ChatViewModel(llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil)

        await vm.send("やあ")

        #expect(llm.callCount == 1)
        #expect(vm.isRunning == false)
        #expect(vm.errorMessage == nil)
        // 表示: user ターン + assistant ターン。
        #expect(vm.turns.count == 2)
        #expect(vm.turns[0].role == .user)
        #expect(vm.turns[1].role == .assistant)
        #expect(vm.turns[1].text == "こんにちは")
        #expect(vm.turns[1].usage == usage(10, 5))
        #expect(vm.lastUsage == usage(10, 5))
        #expect(vm.cumulativeUsage == usage(10, 5))
        // ツールは呼ばれない。
        #expect(await executor.calls.isEmpty)
    }

    // 2) 単一 tool_call → executor が結果を返す → 2周目で .stop。role:tool が積まれ最終テキストが出る。
    @Test func 単一toolCallで2周して確定() async {
        let llm = ScriptedLLMClient(scripts: [
            // 1周目: ツールを呼ぶ。
            [.completed(.toolCalls, [toolCall(id: "c1", name: "get_weather", arguments: "{\"city\":\"Tokyo\"}")], usage(20, 3))],
            // 2周目: ツール結果を見て回答。
            [.textDelta("東京は晴れ"), .completed(.stop, [], usage(30, 8))],
        ])
        let executor = StubToolExecutor(results: ["get_weather": .object(["temp": .int(30)])])
        let vm = ChatViewModel(llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil)

        await vm.send("東京の天気は?")

        #expect(llm.callCount == 2)
        #expect(vm.errorMessage == nil)
        // executor が正しい name/arguments で呼ばれた。
        let calls = await executor.calls
        #expect(calls.count == 1)
        #expect(calls[0].name == "get_weather")
        #expect(calls[0].arguments == .object(["city": .string("Tokyo")]))
        // 最終 assistant テキスト。
        #expect(vm.turns.last?.text == "東京は晴れ")
        // usage は2ターンぶん累計。
        #expect(vm.cumulativeUsage == usage(50, 11))
        #expect(vm.lastUsage == usage(30, 8))
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
                toolCall(id: "c_a", name: "toolA", arguments: "{\"x\":1}"),
            ], usage(20, 4))],
            [.textDelta("完了"), .completed(.stop, [], usage(25, 2))],
        ])
        let executor = StubToolExecutor(results: ["toolA": .string("A"), "toolB": .string("B")])
        let vm = ChatViewModel(llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil)

        await vm.send("両方やって")

        // 両方実行。
        let calls = await executor.calls
        #expect(Set(calls.map(\.name)) == ["toolA", "toolB"])
        // 2周目リクエストの role:tool 部分を抜き出し、tool_call_id 昇順で並んでいることを確認。
        let toolMsgs = llm.receivedRequests[1].messages.filter { $0.role == .tool }
        #expect(toolMsgs.count == 2)
        #expect(toolMsgs.map(\.toolCallId) == ["c_a", "c_b"])
        // 表示ステップは call 順(toolB, toolA)で2件・両方 done。
        let steps = vm.turns.first(where: { !$0.toolSteps.isEmpty })?.toolSteps ?? []
        #expect(steps.map(\.toolName) == ["toolB", "toolA"])
        #expect(steps.allSatisfy { $0.state == .done })
    }

    // 4) 最大反復ガード: 毎回 .toolCalls を返し続ける → maxIterations で打ち切りエラー。
    @Test func 最大反復で打ち切りエラー() async {
        let llm = ScriptedLLMClient(scripts: [
            // 台本は1本。ScriptedLLMClient は台本を超えたら最後を使い回すので毎回これが返る。
            [.completed(.toolCalls, [toolCall(id: "loop", name: "spin", arguments: "{}")], usage(1, 1))],
        ])
        let executor = StubToolExecutor(results: ["spin": .null])
        let vm = ChatViewModel(llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil, maxIterations: 3)

        await vm.send("回り続けて")

        #expect(llm.callCount == 3)
        #expect(vm.errorMessage != nil)
        #expect(vm.isRunning == false)
    }

    // 5) ツール実行 throw → 該当ステップ failed・role:tool に error・ループ継続で次の補完へ。
    @Test func ツール失敗でも継続し次補完へ() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.toolCalls, [toolCall(id: "e1", name: "flaky", arguments: "{}")], usage(5, 1))],
            [.textDelta("失敗したので別の方法を試します"), .completed(.stop, [], usage(6, 2))],
        ])
        let executor = StubToolExecutor(throwing: ["flaky"])
        let vm = ChatViewModel(llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil)

        await vm.send("flaky を呼んで")

        // ループは継続して2周目まで回った(= 打ち切りエラーではない)。
        #expect(llm.callCount == 2)
        #expect(vm.errorMessage == nil)
        #expect(vm.turns.last?.text == "失敗したので別の方法を試します")
        // 該当ステップが failed。
        let steps = vm.turns.first(where: { !$0.toolSteps.isEmpty })?.toolSteps ?? []
        #expect(steps.count == 1)
        #expect(steps[0].state == .failed)
        // 2周目リクエストの role:tool にエラー文言が載っている。
        let toolMsg = llm.receivedRequests[1].messages.first { $0.role == .tool }
        #expect(toolMsg?.content?.contains("エラー") == true)
    }

    // 6) UI 資源を持つツールが成功 → そのターンの cards に CardEmbed が1件・structuredContent と
    //    arguments が入る(設計 §4・二重配布の (b))。role:tool の JSON 配布も従来どおり維持される。
    @Test func UI資源ツール成功でカードが記録される() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.toolCalls, [toolCall(id: "c1", name: "list-todos", arguments: "{\"filter\":\"open\"}")], usage(20, 3))],
            [.textDelta("一覧です"), .completed(.stop, [], usage(30, 8))],
        ])
        let structured: JSONValue = .object(["todos": .array([.string("a")])])
        let executor = StubToolExecutor(results: ["list-todos": structured])
        let vm = ChatViewModel(
            llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil,
            uiResourceURIs: ["list-todos": "ui://todos/list"])

        await vm.send("todos 見せて")

        // カードは assistant ターン(tool_calls を出した1周目のターン)に積まれる。
        let cardTurn = vm.turns.first(where: { !$0.cards.isEmpty })
        let cards = cardTurn?.cards ?? []
        #expect(cards.count == 1)
        #expect(cards[0].toolName == "list-todos")
        #expect(cards[0].resourceUri == "ui://todos/list")
        #expect(cards[0].structuredContent == structured)
        #expect(cards[0].arguments == .object(["filter": .string("open")]))
        // 二重配布維持: role:tool テキストも従来どおり LLM へ渡る(JSON)。
        let toolMsg = llm.receivedRequests[1].messages.first { $0.role == .tool }
        #expect(toolMsg?.content?.contains("todos") == true)
    }

    // 7) uiResourceURIs に無いツールはカードを作らない(UI を持たないツール)。
    @Test func UI資源を持たないツールはカードを作らない() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.toolCalls, [toolCall(id: "c1", name: "plain-tool", arguments: "{}")], usage(5, 1))],
            [.textDelta("done"), .completed(.stop, [], usage(6, 2))],
        ])
        let executor = StubToolExecutor(results: ["plain-tool": .string("ok")])
        let vm = ChatViewModel(
            llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil,
            uiResourceURIs: ["list-todos": "ui://todos/list"])  // plain-tool は含まない。

        await vm.send("実行して")

        #expect(vm.turns.allSatisfy { $0.cards.isEmpty })
    }

    // 8) 失敗したツールはカードを作らない(UI 資源を持っていても・成功時のみ描画)。
    @Test func 失敗したUI資源ツールはカードを作らない() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.toolCalls, [toolCall(id: "c1", name: "list-todos", arguments: "{}")], usage(5, 1))],
            [.textDelta("失敗しました"), .completed(.stop, [], usage(6, 2))],
        ])
        let executor = StubToolExecutor(throwing: ["list-todos"])
        let vm = ChatViewModel(
            llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil,
            uiResourceURIs: ["list-todos": "ui://todos/list"])

        await vm.send("todos 見せて")

        #expect(vm.turns.allSatisfy { $0.cards.isEmpty })
    }

    // 設計 03 §1 決定(b) 検証: 空文字/空オブジェクトはどちらも `.object([:])`(nil ではない)。
    @Test func decodeArguments_空文字と空オブジェクトはobjectEmptyを返す() {
        #expect(ChatViewModel.decodeArguments("") == .value(.object([:])))
        #expect(ChatViewModel.decodeArguments("   ") == .value(.object([:])))
        #expect(ChatViewModel.decodeArguments("{}") == .value(.object([:])))
    }

    // 設計 03 §1 決定(c) 検証: 壊れた JSON は `.invalid` になり、execute はツールを呼ばずに
    // role:"tool" へエラー文言を積む(ループは止めない)。
    @Test func decodeArguments_壊れJSONはinvalid() {
        guard case .invalid(let message) = ChatViewModel.decodeArguments("{\"a\":") else {
            Issue.record("壊れた JSON が .invalid にならなかった")
            return
        }
        #expect(message.contains("不正"))
    }

    @Test func 壊れJSONの引数はツール未実行でrole_toolにエラーが積まれる() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.toolCalls, [toolCall(id: "c1", name: "list-todos", arguments: "{\"a\":")], usage(5, 1))],
            [.textDelta("直します"), .completed(.stop, [], usage(6, 2))],
        ])
        let executor = StubToolExecutor(results: ["list-todos": .object([:])])
        let vm = ChatViewModel(llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil)

        await vm.send("壊れた引数で呼んで")

        // executor は一度も呼ばれない(壊れた JSON を {} に化けさせて成功させない)。
        #expect(await executor.calls.isEmpty)
        // 該当ステップは failed。
        let steps = vm.turns.first(where: { !$0.toolSteps.isEmpty })?.toolSteps ?? []
        #expect(steps.count == 1)
        #expect(steps[0].state == .failed)
        // role:tool にエラー文言が積まれ、モデルへ渡っている。
        let toolMsg = llm.receivedRequests[1].messages.first { $0.role == .tool }
        #expect(toolMsg?.content?.contains("不正") == true)
    }

    // 設計 03 §2 決定2 検証: isError:true の結果ではカードを作らない(uiResourceURIs にあっても)。
    @Test func isErrorTrueの結果はカードを作らない() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.toolCalls, [toolCall(id: "c1", name: "list-todos", arguments: "{}")], usage(5, 1))],
            [.textDelta("引数が不正でした"), .completed(.stop, [], usage(6, 2))],
        ])
        // caldav の TS SDK は失敗を throw ではなく isError:true の正常応答として返す(設計 03 §1)。
        let errorResult: JSONValue = .object(["isError": .bool(true), "content": .array([])])
        let executor = StubToolExecutor(results: ["list-todos": errorResult])
        let vm = ChatViewModel(
            llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil,
            uiResourceURIs: ["list-todos": "ui://todos/list"])

        await vm.send("todos 見せて")

        #expect(vm.turns.allSatisfy { $0.cards.isEmpty })
        // role:tool へは isError の JSON がそのまま配布される(モデルがリトライ判断できるように)。
        let toolMsg = llm.receivedRequests[1].messages.first { $0.role == .tool }
        #expect(toolMsg?.content?.contains("isError") == true)
    }

    // isError:false(通常の成功結果)なら従来どおりカードが作られる(対照テスト)。
    @Test func isErrorFalseの結果はカードを作る() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.toolCalls, [toolCall(id: "c1", name: "list-todos", arguments: "{}")], usage(5, 1))],
            [.textDelta("一覧です"), .completed(.stop, [], usage(6, 2))],
        ])
        let okResult: JSONValue = .object(["isError": .bool(false), "structuredContent": .object(["todos": .array([])])])
        let executor = StubToolExecutor(results: ["list-todos": okResult])
        let vm = ChatViewModel(
            llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil,
            uiResourceURIs: ["list-todos": "ui://todos/list"])

        await vm.send("todos 見せて")

        let cards = vm.turns.first(where: { !$0.cards.isEmpty })?.cards ?? []
        #expect(cards.count == 1)
        #expect(cards[0].toolName == "list-todos")
    }

    // system プロンプトが履歴先頭に固定注入され、毎リクエストに載る。
    @Test func systemプロンプトが毎リクエスト先頭に載る() async {
        let llm = ScriptedLLMClient(scripts: [[.completed(.stop, [], nil)]])
        let vm = ChatViewModel(llm: llm, toolExecutor: StubToolExecutor(), tools: [], model: "m", systemPrompt: "あなたは助手")

        await vm.send("hi")

        let msgs = llm.receivedRequests[0].messages
        #expect(msgs.first?.role == .system)
        #expect(msgs.first?.content == "あなたは助手")
    }
}

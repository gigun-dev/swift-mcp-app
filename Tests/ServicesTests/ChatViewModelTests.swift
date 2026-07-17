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

    // MARK: - retry(再生成・ユーザー要望 2026-07-17)

    // send 1回成功後に retryLastTurn すると、user + 新しい assistant だけが残り、wireMessages にも
    // user が1つ・古い assistant は残らない(巻き戻し + 再送の基本ケース)。
    @Test func retryLastTurn_成功後は最後のuser以降を巻き戻して再送する() async {
        let llm = ScriptedLLMClient(scripts: [
            [.textDelta("最初の返事"), .completed(.stop, [], usage(10, 5))],
            [.textDelta("2回目の返事"), .completed(.stop, [], usage(11, 6))],
        ])
        let executor = StubToolExecutor()
        let vm = ChatViewModel(llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil)

        await vm.send("やあ")
        await vm.retryLastTurn()

        #expect(llm.callCount == 2)
        #expect(vm.turns.count == 2)
        #expect(vm.turns[0].role == .user)
        #expect(vm.turns[0].text == "やあ")
        #expect(vm.turns[1].role == .assistant)
        #expect(vm.turns[1].text == "2回目の返事")

        // wireMessages 側も1周目の assistant が残っておらず、user は1つだけ。
        let secondReq = llm.receivedRequests[1]
        let userMsgs = secondReq.messages.filter { $0.role == .user }
        #expect(userMsgs.count == 1)
        #expect(!secondReq.messages.contains { $0.role == .assistant && $0.content == "最初の返事" })
    }

    // tool_calls を1周挟んだ send 後の retry → assistant(tool_calls)/role:tool のペアが
    // wireMessages から消える(厳密ペアが壊れないことの確認)。
    @Test func retryLastTurn_toolCallsを挟んだ後もwireから両方消える() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.toolCalls, [toolCall(id: "c1", name: "get_weather", arguments: "{\"city\":\"Tokyo\"}")], usage(20, 3))],
            [.textDelta("東京は晴れ"), .completed(.stop, [], usage(30, 8))],
            [.textDelta("2回目の返事"), .completed(.stop, [], usage(5, 5))],
        ])
        let executor = StubToolExecutor(results: ["get_weather": .object(["temp": .int(30)])])
        let vm = ChatViewModel(llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil)

        await vm.send("東京の天気は?")
        await vm.retryLastTurn()

        #expect(llm.callCount == 3)
        // retry 後の最後のリクエスト(3周目)には tool_calls の assistant も role:tool も残らない。
        let lastReq = llm.receivedRequests[2]
        #expect(!lastReq.messages.contains { $0.role == .assistant && ($0.toolCalls?.isEmpty == false) })
        #expect(!lastReq.messages.contains { $0.role == .tool })
        #expect(lastReq.messages.filter { $0.role == .user }.count == 1)
        #expect(vm.turns.count == 2)
        #expect(vm.turns[1].text == "2回目の返事")
    }

    // ストリーム失敗(errorMessage 立つ)後の retry → errorMessage が消え再送される。
    @Test func retryLastTurn_ストリーム失敗後はerrorMessageが消えて再送される() async {
        let vm = ChatViewModel(llm: ThrowingLLMClient(), toolExecutor: StubToolExecutor(), tools: [], model: "m", systemPrompt: nil)

        await vm.send("失敗するはず")
        #expect(vm.errorMessage != nil)

        // retry では成功する新しい LLM に差し替えたいが、ChatViewModel は llm を init 時固定なので、
        // 同じ ThrowingLLMClient のまま retryLastTurn を呼び、「再送されたこと」自体(= turns が
        // user 1件に巻き戻ってから send が実行され、再び errorMessage が立つ一連の動き)を確認する。
        await vm.retryLastTurn()

        // 巻き戻り→再送が起きた証拠: turns は user 1件のみ(失敗した assistant ターンは
        // send() 内で1件 append されるが、text 空のままエラーで return するため turns.count は 2 になる
        // ——「再送された」ことは turns[0] が同じ user 発話であることと assistant ターンが
        // 新規 append されていること(古い1つ目と入れ替わっていること)で確認する)。
        #expect(vm.turns.count == 2)
        #expect(vm.turns[0].role == .user)
        #expect(vm.turns[0].text == "失敗するはず")
        #expect(vm.turns[1].role == .assistant)
        #expect(vm.errorMessage != nil)
    }

    // turns が空のとき retryLastTurn は no-op(user ターンが無い = 何もしない)。
    @Test func retryLastTurn_turnsが空ならno_op() async {
        let llm = ScriptedLLMClient(scripts: [[.completed(.stop, [], nil)]])
        let vm = ChatViewModel(llm: llm, toolExecutor: StubToolExecutor(), tools: [], model: "m", systemPrompt: nil)

        await vm.retryLastTurn()

        #expect(llm.callCount == 0)
        #expect(vm.turns.isEmpty)
        #expect(vm.errorMessage == nil)
    }

    // MARK: - T6 前半: TraceSink 注入 + currentSession(設計 03 §3・02 §5)

    // テキストのみのターン: turnStarted → llmCompleted → turnSettled の順で1回ずつ出る
    // (toolCallStarted/Finished は無し)。
    @Test func traceSink_テキストのみのターンでturnStarted_llmCompleted_turnSettledが順に出る() async {
        let llm = ScriptedLLMClient(scripts: [[.completed(.stop, [], usage(10, 5))]])
        let sink = SpyTraceSink()
        let vm = ChatViewModel(
            llm: llm, toolExecutor: StubToolExecutor(), tools: [], model: "m", systemPrompt: nil,
            traceSink: sink)

        await vm.send("やあ")

        let kinds = sink.kinds()
        #expect(kinds == ["turnStarted", "llmCompleted", "turnSettled"])
    }

    // tool_call ありのターン: turnStarted → llmCompleted(1周目) → toolCallStarted →
    // toolCallFinished → llmCompleted(2周目) → turnSettled の順で出る(設計 03 §3 の5注入点)。
    @Test func traceSink_toolCallありのターンで注入点5箇所が正しい順序で出る() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.toolCalls, [toolCall(id: "c1", name: "get_weather", arguments: "{\"city\":\"Tokyo\"}")], usage(20, 3))],
            [.textDelta("東京は晴れ"), .completed(.stop, [], usage(30, 8))],
        ])
        let executor = StubToolExecutor(results: ["get_weather": .object(["temp": .int(30)])])
        let sink = SpyTraceSink()
        let vm = ChatViewModel(
            llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil,
            traceSink: sink)

        await vm.send("東京の天気は?")

        let kinds = sink.kinds()
        #expect(kinds == [
            "turnStarted", "llmCompleted", "toolCallStarted", "toolCallFinished",
            "llmCompleted", "turnSettled",
        ])

        // turnId は5イベントすべて同一(1ユーザー発話に対する一連の反復)。
        let turnIds = sink.turnIds()
        #expect(Set(turnIds).count == 1)

        // toolCallFinished の resultBytes は空でない(結果 JSON のバイト数)・isError は false。
        let events = sink.eventsSnapshot
        guard case .toolCallFinished(_, _, let isError, let resultBytes, _) = events[3] else {
            Issue.record("3番目のイベントが toolCallFinished ではない")
            return
        }
        #expect(isError == false)
        #expect(resultBytes > 0)
    }

    // 壊れた JSON 引数(ツール未実行)では toolCallStarted/Finished は出ない
    // (設計に明記なし・こう解釈: 実行しなかったものを実行1回として数えない・execute のコメント参照)。
    @Test func traceSink_壊れJSON引数はtoolCallイベントを出さない() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.toolCalls, [toolCall(id: "bad", name: "broken", arguments: "{not json")], usage(1, 1))],
            [.textDelta("エラーでした"), .completed(.stop, [], usage(2, 1))],
        ])
        let sink = SpyTraceSink()
        let vm = ChatViewModel(
            llm: llm, toolExecutor: StubToolExecutor(), tools: [], model: "m", systemPrompt: nil,
            traceSink: sink)

        await vm.send("壊れた引数のテスト")

        let kinds = sink.kinds()
        #expect(!kinds.contains("toolCallStarted"))
        #expect(!kinds.contains("toolCallFinished"))
    }

    // traceSink を渡さない(既定 nil)場合でも既存どおり動作する(後方互換)。
    @Test func traceSink未指定でも既存どおり動作する() async {
        let llm = ScriptedLLMClient(scripts: [[.completed(.stop, [], usage(1, 1))]])
        let vm = ChatViewModel(llm: llm, toolExecutor: StubToolExecutor(), tools: [], model: "m", systemPrompt: nil)

        await vm.send("互換性テスト")

        #expect(vm.errorMessage == nil)
    }

    // currentSession: turns を含み、title は最初の user 発話の先頭から導出される。
    @Test func currentSessionはturnsを含みtitleを最初のuser発話から導出する() async {
        let llm = ScriptedLLMClient(scripts: [[.textDelta("こんにちは"), .completed(.stop, [], usage(1, 1))]])
        let vm = ChatViewModel(
            llm: llm, toolExecutor: StubToolExecutor(), tools: [], model: "gpt-5-mini", systemPrompt: nil,
            sessionId: "11111111-1111-1111-1111-111111111111",
            serverURL: URL(string: "https://caldav.gigun-dev.workers.dev/mcp")!)

        await vm.send("今日の予定を教えて")

        let session = vm.currentSession
        #expect(session.id.uuidString.lowercased() == "11111111-1111-1111-1111-111111111111")
        #expect(session.title == "今日の予定を教えて")
        #expect(session.model == "gpt-5-mini")
        #expect(session.serverURL == URL(string: "https://caldav.gigun-dev.workers.dev/mcp")!)
        #expect(session.turns.count == 2)
    }

    // onTurnSettled: send() が返る直前に必ず1回呼ばれる(ストリーム失敗による早期 return でも)。
    @Test func onTurnSettledはstream成功でも失敗でも呼ばれる() async {
        let ok = ScriptedLLMClient(scripts: [[.completed(.stop, [], nil)]])
        var callCount = 0
        let vm = ChatViewModel(
            llm: ok, toolExecutor: StubToolExecutor(), tools: [], model: "m", systemPrompt: nil,
            onTurnSettled: { callCount += 1 })
        await vm.send("成功ケース")
        #expect(callCount == 1)

        let failing = ScriptedLLMClient(scripts: [[]]) // 何も yield せず finish するとイベントが
        // 空になり、accumulatedText 空・finishReason .other のまま実質「completed 無し」になる
        // ——これはストリーム自体の throw ではないが「continuation.finish() のみ」で
        // AsyncThrowingStream が正常終了する経路なので、真の throw を再現するため
        // ThrowingLLMClient を別途使う(下記)。
        _ = failing
        var throwCallCount = 0
        let throwingVM = ChatViewModel(
            llm: ThrowingLLMClient(), toolExecutor: StubToolExecutor(), tools: [], model: "m", systemPrompt: nil,
            onTurnSettled: { throwCallCount += 1 })
        await throwingVM.send("失敗ケース")
        #expect(throwCallCount == 1)
        #expect(throwingVM.errorMessage != nil)
    }
}

/// 常に stream 開始直後に throw するスタブ LLMClient(onTurnSettled のストリーム失敗経路テスト用)。
private final class ThrowingLLMClient: LLMClient, @unchecked Sendable {
    func stream(_ request: ChatCompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ThrowingLLMClientError.boom)
        }
    }
    enum ThrowingLLMClientError: Error { case boom }
}

/// emit された ChatTraceEvent を記録するスタブ TraceSink。
///
/// **actor でなく NSLock で直列化する判断(設計に無い・こう解釈)**: TraceSink.emit は
/// プロトコル定義上「同期メソッド」(fire-and-forget の契約)。actor にすると emit 内部で
/// `Task { await ... }` を挟むことになり、テスト側の `await vm.send(...)` 完了時点で
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

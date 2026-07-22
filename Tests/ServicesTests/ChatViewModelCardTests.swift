// ChatViewModel のMCP Appsカード生成・snapshot同一性・tool結果解釈を検証する。
// 元の統合suiteと同じ直列化境界を保つため、ChatViewModelTestsのextensionとして分割する。
import Foundation
import Testing

@testable import Kernel
@testable import Services

@MainActor
extension ChatViewModelTests {
    @Test func UI資源ツール成功でカードが記録される() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(
                .toolCalls,
                [toolCall(id: "c1", name: "list-todos", arguments: "{\"filter\":\"open\"}")],
                usage(20, 3)
            )],
            [.textDelta("一覧です"), .completed(.stop, [], usage(30, 8))]
        ])
        let structured: JSONValue = .object(["todos": .array([.string("a")])])
        let executor = StubToolExecutor(results: ["list-todos": structured])
        let viewModel = ChatViewModel(
            llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil,
            uiResourceURIs: ["list-todos": "ui://todos/list"])

        await viewModel.send("todos 見せて")

        // カードは assistant ターン(tool_calls を出した1周目のターン)に積まれる。
        let cardTurn = viewModel.turns.first(where: { !$0.cards.isEmpty })
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

    // MARK: - 監査 2026-07-18 LOW: setCardSnapshot の card 同一性チェック

    // expectedResourceUri がその位置の実カードと一致すれば書き戻せる(正常系)。
    @Test func setCardSnapshot_resourceUriが一致すれば書き戻せる() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.toolCalls, [toolCall(id: "c1", name: "list-todos", arguments: "{}")], usage(1, 1))],
            [.completed(.stop, [], usage(1, 1))]
        ])
        let executor = StubToolExecutor(results: ["list-todos": .object([:])])
        let viewModel = ChatViewModel(
            llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil,
            uiResourceURIs: ["list-todos": "ui://todos/list"])
        await viewModel.send("todos 見せて")

        let cardTurnIndex = viewModel.turns.firstIndex(where: { !$0.cards.isEmpty })!
        viewModel.setCardSnapshot(
            turnIndex: cardTurnIndex, cardIndex: 0,
            expectedResourceUri: "ui://todos/list", html: "<html>snap</html>")

        #expect(viewModel.turns[cardTurnIndex].cards[0].snapshotHTML == "<html>snap</html>")
    }

    // expectedResourceUri がその位置の実カードと不一致なら黙って捨てる(退避先が別カードに
    // 入れ替わっていた場合の防御・監査 2026-07-18 LOW)。
    @Test func setCardSnapshot_resourceUriが不一致なら無視する() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.toolCalls, [toolCall(id: "c1", name: "list-todos", arguments: "{}")], usage(1, 1))],
            [.completed(.stop, [], usage(1, 1))]
        ])
        let executor = StubToolExecutor(results: ["list-todos": .object([:])])
        let viewModel = ChatViewModel(
            llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil,
            uiResourceURIs: ["list-todos": "ui://todos/list"])
        await viewModel.send("todos 見せて")

        let cardTurnIndex = viewModel.turns.firstIndex(where: { !$0.cards.isEmpty })!
        // 位置は合っているが、届いた identity(resourceUri)が違う=旧カードの遅延スナップショット
        // が別カードへ書き込まれかけているケースを模す。
        viewModel.setCardSnapshot(
            turnIndex: cardTurnIndex, cardIndex: 0,
            expectedResourceUri: "ui://agenda/view", html: "<html>stale-snap</html>")

        #expect(viewModel.turns[cardTurnIndex].cards[0].snapshotHTML == nil)
    }

    // 7) uiResourceURIs に無いツールはカードを作らない(UI を持たないツール)。
    @Test func UI資源を持たないツールはカードを作らない() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.toolCalls, [toolCall(id: "c1", name: "plain-tool", arguments: "{}")], usage(5, 1))],
            [.textDelta("done"), .completed(.stop, [], usage(6, 2))]
        ])
        let executor = StubToolExecutor(results: ["plain-tool": .string("ok")])
        let viewModel = ChatViewModel(
            llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil,
            uiResourceURIs: ["list-todos": "ui://todos/list"])  // plain-tool は含まない。

        await viewModel.send("実行して")

        #expect(viewModel.turns.allSatisfy { $0.cards.isEmpty })
    }

    // 8) 失敗したツールはカードを作らない(UI 資源を持っていても・成功時のみ描画)。
    @Test func 失敗したUI資源ツールはカードを作らない() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.toolCalls, [toolCall(id: "c1", name: "list-todos", arguments: "{}")], usage(5, 1))],
            [.textDelta("失敗しました"), .completed(.stop, [], usage(6, 2))]
        ])
        let executor = StubToolExecutor(throwing: ["list-todos"])
        let viewModel = ChatViewModel(
            llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil,
            uiResourceURIs: ["list-todos": "ui://todos/list"])

        await viewModel.send("todos 見せて")

        #expect(viewModel.turns.allSatisfy { $0.cards.isEmpty })
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
            [.textDelta("直します"), .completed(.stop, [], usage(6, 2))]
        ])
        let executor = StubToolExecutor(results: ["list-todos": .object([:])])
        let viewModel = ChatViewModel(llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil)

        await viewModel.send("壊れた引数で呼んで")

        // executor は一度も呼ばれない(壊れた JSON を {} に化けさせて成功させない)。
        #expect(await executor.calls.isEmpty)
        // 該当ステップは failed。
        let steps = viewModel.turns.first(where: { !$0.toolSteps.isEmpty })?.toolSteps ?? []
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
            [.textDelta("引数が不正でした"), .completed(.stop, [], usage(6, 2))]
        ])
        // caldav の TS SDK は失敗を throw ではなく isError:true の正常応答として返す(設計 03 §1)。
        let errorResult: JSONValue = .object(["isError": .bool(true), "content": .array([])])
        let executor = StubToolExecutor(results: ["list-todos": errorResult])
        let viewModel = ChatViewModel(
            llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil,
            uiResourceURIs: ["list-todos": "ui://todos/list"])

        await viewModel.send("todos 見せて")

        #expect(viewModel.turns.allSatisfy { $0.cards.isEmpty })
        // role:tool へは isError の JSON がそのまま配布される(モデルがリトライ判断できるように)。
        let toolMsg = llm.receivedRequests[1].messages.first { $0.role == .tool }
        #expect(toolMsg?.content?.contains("isError") == true)
    }

    // isError:false(通常の成功結果)なら従来どおりカードが作られる(対照テスト)。
    @Test func isErrorFalseの結果はカードを作る() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.toolCalls, [toolCall(id: "c1", name: "list-todos", arguments: "{}")], usage(5, 1))],
            [.textDelta("一覧です"), .completed(.stop, [], usage(6, 2))]
        ])
        let okResult: JSONValue = .object([
            "isError": .bool(false),
            "structuredContent": .object(["todos": .array([])])
        ])
        let executor = StubToolExecutor(results: ["list-todos": okResult])
        let viewModel = ChatViewModel(
            llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil,
            uiResourceURIs: ["list-todos": "ui://todos/list"])

        await viewModel.send("todos 見せて")

        let cards = viewModel.turns.first(where: { !$0.cards.isEmpty })?.cards ?? []
        #expect(cards.count == 1)
        #expect(cards[0].toolName == "list-todos")
    }

    // system プロンプトが履歴先頭に固定注入され、毎リクエストに載る。
}

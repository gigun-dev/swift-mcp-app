// ChatViewModel のTraceSink・session snapshot・settled callbackを検証する。
// 元の統合suiteと同じ直列化境界を保つため、ChatViewModelTestsのextensionとして分割する。
import Foundation
import Testing

@testable import Kernel
@testable import Services

@MainActor
extension ChatViewModelTests {
    // MARK: - T6 前半: TraceSink 注入 + currentSession(設計 03 §3・02 §5)

    // テキストのみのターン: turnStarted → llmCompleted → turnSettled の順で1回ずつ出る
    // (toolCallStarted/Finished は無し)。
    @Test func traceSink_テキストのみのターンでturnStarted_llmCompleted_turnSettledが順に出る() async {
        let llm = ScriptedLLMClient(scripts: [[.completed(.stop, [], usage(10, 5))]])
        let sink = SpyTraceSink()
        let viewModel = ChatViewModel(
            llm: llm, toolExecutor: StubToolExecutor(), tools: [], model: "m", systemPrompt: nil,
            traceSink: sink)

        await viewModel.send("やあ")

        let kinds = sink.kinds()
        #expect(kinds == ["turnStarted", "llmCompleted", "turnSettled"])
    }

    // tool_call ありのターン: turnStarted → llmCompleted(1周目) → toolCallStarted →
    // toolCallFinished → llmCompleted(2周目) → turnSettled の順で出る(設計 03 §3 の5注入点)。
    @Test func traceSink_toolCallありのターンで注入点5箇所が正しい順序で出る() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(
                .toolCalls,
                [toolCall(id: "c1", name: "get_weather", arguments: "{\"city\":\"Tokyo\"}")],
                usage(20, 3)
            )],
            [.textDelta("東京は晴れ"), .completed(.stop, [], usage(30, 8))]
        ])
        let executor = StubToolExecutor(results: ["get_weather": .object(["temp": .int(30)])])
        let sink = SpyTraceSink()
        let viewModel = ChatViewModel(
            llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil,
            traceSink: sink)

        await viewModel.send("東京の天気は?")

        let kinds = sink.kinds()
        #expect(kinds == [
            "turnStarted", "llmCompleted", "toolCallStarted", "toolCallFinished",
            "llmCompleted", "turnSettled"
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
            [.textDelta("エラーでした"), .completed(.stop, [], usage(2, 1))]
        ])
        let sink = SpyTraceSink()
        let viewModel = ChatViewModel(
            llm: llm, toolExecutor: StubToolExecutor(), tools: [], model: "m", systemPrompt: nil,
            traceSink: sink)

        await viewModel.send("壊れた引数のテスト")

        let kinds = sink.kinds()
        #expect(!kinds.contains("toolCallStarted"))
        #expect(!kinds.contains("toolCallFinished"))
    }

    // traceSink を渡さない(既定 nil)場合でも既存どおり動作する(後方互換)。
    @Test func traceSink未指定でも既存どおり動作する() async {
        let llm = ScriptedLLMClient(scripts: [[.completed(.stop, [], usage(1, 1))]])
        let viewModel = ChatViewModel(
            llm: llm,
            toolExecutor: StubToolExecutor(),
            tools: [],
            model: "m",
            systemPrompt: nil
        )

        await viewModel.send("互換性テスト")

        #expect(viewModel.errorMessage == nil)
    }

    // currentSession: turns を含み、title は最初の user 発話の先頭から導出される。
    @Test func currentSessionはturnsを含みtitleを最初のuser発話から導出する() async {
        let llm = ScriptedLLMClient(scripts: [[.textDelta("こんにちは"), .completed(.stop, [], usage(1, 1))]])
        let viewModel = ChatViewModel(
            llm: llm, toolExecutor: StubToolExecutor(), tools: [], model: "gpt-5-mini", systemPrompt: nil,
            sessionId: "11111111-1111-1111-1111-111111111111",
            serverURL: URL(string: "https://caldav.gigun-dev.workers.dev/mcp")!)

        await viewModel.send("今日の予定を教えて")

        let session = viewModel.currentSession
        #expect(session.id.uuidString.lowercased() == "11111111-1111-1111-1111-111111111111")
        #expect(session.title == "今日の予定を教えて")
        #expect(session.model == "gpt-5-mini")
        #expect(session.serverURL == URL(string: "https://caldav.gigun-dev.workers.dev/mcp")!)
        #expect(session.turns.count == 2)
    }

    // onTurnSettled: send() が返る直前に必ず1回呼ばれる(ストリーム失敗による早期 return でも)。
    @Test func onTurnSettledはstream成功でも失敗でも呼ばれる() async {
        let successfulClient = ScriptedLLMClient(scripts: [[.completed(.stop, [], nil)]])
        var callCount = 0
        let viewModel = ChatViewModel(
            llm: successfulClient, toolExecutor: StubToolExecutor(), tools: [], model: "m", systemPrompt: nil,
            onTurnSettled: { callCount += 1 })
        await viewModel.send("成功ケース")
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

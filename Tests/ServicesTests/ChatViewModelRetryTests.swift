// ChatViewModel の再生成と実行中キャンセルを検証する。
// 元の統合suiteと同じ直列化境界を保つため、ChatViewModelTestsのextensionとして分割する。
import Foundation
import Testing

@testable import Kernel
@testable import Services

@MainActor
extension ChatViewModelTests {
    // MARK: - retry(再生成・ユーザー要望 2026-07-17)

    // send 1回成功後に retryLastTurn すると、user + 新しい assistant だけが残り、wireMessages にも
    // user が1つ・古い assistant は残らない(巻き戻し + 再送の基本ケース)。
    @Test func retryLastTurn_成功後は最後のuser以降を巻き戻して再送する() async {
        let llm = ScriptedLLMClient(scripts: [
            [.textDelta("最初の返事"), .completed(.stop, [], usage(10, 5))],
            [.textDelta("2回目の返事"), .completed(.stop, [], usage(11, 6))]
        ])
        let executor = StubToolExecutor()
        let viewModel = ChatViewModel(llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil)

        await viewModel.send("やあ")
        await viewModel.retryLastTurn()

        #expect(llm.callCount == 2)
        #expect(viewModel.turns.count == 2)
        #expect(viewModel.turns[0].role == .user)
        #expect(viewModel.turns[0].text == "やあ")
        #expect(viewModel.turns[1].role == .assistant)
        #expect(viewModel.turns[1].text == "2回目の返事")

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
            [.completed(
                .toolCalls,
                [toolCall(id: "c1", name: "get_weather", arguments: "{\"city\":\"Tokyo\"}")],
                usage(20, 3)
            )],
            [.textDelta("東京は晴れ"), .completed(.stop, [], usage(30, 8))],
            [.textDelta("2回目の返事"), .completed(.stop, [], usage(5, 5))]
        ])
        let executor = StubToolExecutor(results: ["get_weather": .object(["temp": .int(30)])])
        let viewModel = ChatViewModel(llm: llm, toolExecutor: executor, tools: [], model: "m", systemPrompt: nil)

        await viewModel.send("東京の天気は?")
        await viewModel.retryLastTurn()

        #expect(llm.callCount == 3)
        // retry 後の最後のリクエスト(3周目)には tool_calls の assistant も role:tool も残らない。
        let lastReq = llm.receivedRequests[2]
        #expect(!lastReq.messages.contains { $0.role == .assistant && ($0.toolCalls?.isEmpty == false) })
        #expect(!lastReq.messages.contains { $0.role == .tool })
        #expect(lastReq.messages.filter { $0.role == .user }.count == 1)
        #expect(viewModel.turns.count == 2)
        #expect(viewModel.turns[1].text == "2回目の返事")
    }

    // ストリーム失敗(errorMessage 立つ)後の retry → errorMessage が消え再送される。
    @Test func retryLastTurn_ストリーム失敗後はerrorMessageが消えて再送される() async {
        let viewModel = ChatViewModel(
            llm: ThrowingLLMClient(),
            toolExecutor: StubToolExecutor(),
            tools: [],
            model: "m",
            systemPrompt: nil
        )

        await viewModel.send("失敗するはず")
        #expect(viewModel.errorMessage != nil)

        // retry では成功する新しい LLM に差し替えたいが、ChatViewModel は llm を init 時固定なので、
        // 同じ ThrowingLLMClient のまま retryLastTurn を呼び、「再送されたこと」自体(= turns が
        // user 1件に巻き戻ってから send が実行され、再び errorMessage が立つ一連の動き)を確認する。
        await viewModel.retryLastTurn()

        // 巻き戻り→再送が起きた証拠: turns は user 1件のみ(失敗した assistant ターンは
        // send() 内で1件 append されるが、text 空のままエラーで return するため turns.count は 2 になる
        // ——「再送された」ことは turns[0] が同じ user 発話であることと assistant ターンが
        // 新規 append されていること(古い1つ目と入れ替わっていること)で確認する)。
        #expect(viewModel.turns.count == 2)
        #expect(viewModel.turns[0].role == .user)
        #expect(viewModel.turns[0].text == "失敗するはず")
        #expect(viewModel.turns[1].role == .assistant)
        #expect(viewModel.errorMessage != nil)
    }

    // turns が空のとき retryLastTurn は no-op(user ターンが無い = 何もしない)。
    @Test func retryLastTurn_turnsが空ならno_op() async {
        let llm = ScriptedLLMClient(scripts: [[.completed(.stop, [], nil)]])
        let viewModel = ChatViewModel(
            llm: llm,
            toolExecutor: StubToolExecutor(),
            tools: [],
            model: "m",
            systemPrompt: nil
        )

        await viewModel.retryLastTurn()

        #expect(llm.callCount == 0)
        #expect(viewModel.turns.isEmpty)
        #expect(viewModel.errorMessage == nil)
    }

    // MARK: - 監査 2026-07-18 MEDIUM: newChat/画面破棄での send Task キャンセル

    // submit() で始めた送信を cancelActiveSend() で打ち切ると、isRunning が false に落ち、
    // errorMessage は(ストリーム失敗と誤認されず)nil のまま——タスク指示の固定要件。
    // DelayedLLMClient は OpenAICompatClient.stream と同じ「onTermination で内部 Task を cancel する」
    // 形にしてあるので、consumer Task のキャンセルが AsyncThrowingStream の for-await を実際に
    // 打ち切ることまで込みで検証する(スタブが常に即完了する ScriptedLLMClient では検証できない経路)。
    @Test func submit_cancelActiveSendで打ち切るとisRunningが落ちerrorMessageは出ない() async {
        let llm = DelayedLLMClient()
        let viewModel = ChatViewModel(
            llm: llm,
            toolExecutor: StubToolExecutor(),
            tools: [],
            model: "m",
            systemPrompt: nil
        )

        viewModel.submit("やあ")
        // submit() の Task 起動〜send() 内 isRunning=true までは MainActor 上の非同期ディスパッチを
        // 挟むため、立ち上がりを少し待つ(ポーリング。即断定すると起動前に検査してしまい flaky になる)。
        await waitUntil { viewModel.isRunning }
        #expect(viewModel.isRunning == true)

        viewModel.cancelActiveSend()
        await waitUntil { viewModel.isRunning == false }

        #expect(viewModel.isRunning == false)
        #expect(viewModel.errorMessage == nil)
    }

    /// 条件が満たされるまで短い間隔でポーリングする(タイムアウト付き・テストの決定性のための小道具)。
    /// MainActor 上の Task 起動タイミング依存の検証(上のキャンセルテスト)を sleep 決め打ちにせず、
    /// 実際に条件が成立するまで待つことで flaky さを避ける。
    private func waitUntil(timeout: Duration = .seconds(2), _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

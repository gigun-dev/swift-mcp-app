// ChatViewModel.lastCostUSD / cumulativeCostUSD(T7・設計 §6)の単体テスト。
//
// ChatViewModelTests.swift のスタブ(ScriptedLLMClient / StubToolExecutor)をそのまま再利用する
// (同じ ServicesTests ターゲット内・private でなく internal 定義なので参照できる)。
// このスイートも @Suite(.serialized) にする ——ChatViewModelTests.swift 冒頭コメントの
// teardown SIGSEGV 回避の理由がこのファイルにも等しく当てはまるため(同じ @MainActor
// ChatViewModel を回す新規テストスイート)。
import Foundation
import Testing
@testable import Kernel
@testable import Services

@MainActor
@Suite(.serialized)
struct ChatViewModelCostTests {
    private func usage(_ promptTokens: Int, _ completionTokens: Int) -> Usage {
        Usage(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: promptTokens + completionTokens
        )
    }

    @Test("modelPrice 未設定なら lastCostUSD/cumulativeCostUSD は nil(未知モデルは非表示)")
    func costIsNilWithoutModelPrice() async {
        let llm = ScriptedLLMClient(scripts: [[.completed(.stop, [], usage(10, 5))]])
        let viewModel = ChatViewModel(
            llm: llm,
            toolExecutor: StubToolExecutor(),
            tools: [],
            model: "unknown-model",
            systemPrompt: nil
        )

        await viewModel.send("hi")

        #expect(viewModel.lastUsage == usage(10, 5))
        #expect(viewModel.modelPrice == nil)
        #expect(viewModel.lastCostUSD == nil)
        #expect(viewModel.cumulativeCostUSD == nil)
    }

    @Test("modelPrice 設定後は lastCostUSD/cumulativeCostUSD が usage×単価で計算される")
    func costComputedFromModelPrice() async {
        let llm = ScriptedLLMClient(scripts: [
            [.completed(.stop, [], usage(1000, 500))],
            [.completed(.stop, [], usage(2000, 1000))]
        ])
        let viewModel = ChatViewModel(
            llm: llm,
            toolExecutor: StubToolExecutor(),
            tools: [],
            model: "gpt-4o-mini",
            systemPrompt: nil
        )
        // gpt-4o-mini 級の単価(2026-07-16 litellm 確認・PricingTests と同値)。
        viewModel.modelPrice = ModelPrice(inputCostPerToken: 1.5e-07, outputCostPerToken: 6e-07)

        await viewModel.send("1回目")
        // 1000*1.5e-07 + 500*6e-07 = 4.5e-4
        #expect(viewModel.lastCostUSD.map { abs($0 - 4.5e-4) < 1e-12 } == true)
        #expect(viewModel.cumulativeCostUSD.map { abs($0 - 4.5e-4) < 1e-12 } == true)

        await viewModel.send("2回目")
        // このターン: 2000*1.5e-07 + 1000*6e-07 = 9.0e-4
        #expect(viewModel.lastCostUSD.map { abs($0 - 9.0e-4) < 1e-12 } == true)
        // 累計 usage = (3000, 1500) → 3000*1.5e-07 + 1500*6e-07 = 4.5e-4 + 9.0e-4 = 1.35e-3
        #expect(viewModel.cumulativeCostUSD.map { abs($0 - 1.35e-3) < 1e-11 } == true)
    }

    @Test("modelPrice を後から nil に戻すとコストは再び nil になる(設定変更・接続切替の後入れを反映)")
    func costGoesNilWhenModelPriceClearedAfterSet() async {
        let llm = ScriptedLLMClient(scripts: [[.completed(.stop, [], usage(10, 5))]])
        let viewModel = ChatViewModel(
            llm: llm,
            toolExecutor: StubToolExecutor(),
            tools: [],
            model: "m",
            systemPrompt: nil
        )
        viewModel.modelPrice = ModelPrice(inputCostPerToken: 1e-06, outputCostPerToken: 1e-06)

        await viewModel.send("hi")
        #expect(viewModel.lastCostUSD != nil)

        viewModel.modelPrice = nil
        #expect(viewModel.lastCostUSD == nil)
        #expect(viewModel.cumulativeCostUSD == nil)
    }
}

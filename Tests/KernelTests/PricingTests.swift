// Kernel/Pricing の純関数テスト(T7・設計 §6)。単価×usage の概算計算と ModelPrice の round-trip。
import Foundation
import Testing
@testable import Kernel

@Test("estimatedCostUSD は prompt×input + completion×output")
func estimatedCostUSDComputesLinearCombination() {
    // gpt-4o-mini 級の単価(2026-07-16 litellm 確認・タスク指示に載っている実値)。
    let price = ModelPrice(inputCostPerToken: 1.5e-07, outputCostPerToken: 6e-07)
    let usage = Usage(promptTokens: 1000, completionTokens: 500)
    let cost = estimatedCostUSD(usage: usage, price: price)
    // 1000*1.5e-07 + 500*6e-07 = 1.5e-04 + 3.0e-04 = 4.5e-04
    #expect(abs(cost - 4.5e-4) < 1e-12)
}

@Test("estimatedCostUSD はトークン0で0を返す")
func estimatedCostUSDZeroTokens() {
    let price = ModelPrice(inputCostPerToken: 7.5e-07, outputCostPerToken: 4.5e-06)
    let usage = Usage(promptTokens: 0, completionTokens: 0)
    #expect(estimatedCostUSD(usage: usage, price: price) == 0)
}

@Test("ModelPrice は Codable で round-trip する")
func modelPriceRoundTrip() throws {
    let price = ModelPrice(inputCostPerToken: 7.5e-07, outputCostPerToken: 4.5e-06)
    let data = try JSONEncoder().encode(price)
    let decoded = try JSONDecoder().decode(ModelPrice.self, from: data)
    #expect(decoded == price)
}

// モデル1件ぶんの単価(USD/token)+ 概算コストの純関数。設計 docs/design/02-chat-llm.md §6。
//
// 単価はハードコードしない(§6「単価はハードコードすると陳腐化する」)。ここは値を持たず、
// 「入力/出力トークン単価が分かっているとき、usage から概算コストを出す」純計算だけを置く。
// 単価をどこから取得するか(litellm pricing データの fetch・キャッシュ)は Services/Chat/PricingStore
// (プラットフォーム層・URLSession/FileManager を触る)の責務(Kernel は依存ゼロ・CLAUDE.md)。
import Foundation

/// 1モデルの単価(USD/token)。litellm の `model_prices_and_context_window.json` の
/// `input_cost_per_token` / `output_cost_per_token` をそのまま写す(タスク指示の構造どおり)。
/// キャッシュ/JSON ファイル往復にも使うため Codable。
public struct ModelPrice: Codable, Equatable, Sendable {
    public let inputCostPerToken: Double
    public let outputCostPerToken: Double

    public init(inputCostPerToken: Double, outputCostPerToken: Double) {
        self.inputCostPerToken = inputCostPerToken
        self.outputCostPerToken = outputCostPerToken
    }
}

/// usage(prompt/completion トークン数)× 単価から概算コスト(USD)を出す純関数。
///
/// 「概算」なのは litellm の単価表がプロバイダの実請求と完全一致する保証はない
/// (プロモーション価格・バッチ割引等は反映されない)ためで、設計 §6 が「概算」と
/// 呼んでいるのに合わせる。totalTokens は使わない(prompt/completion の内訳が要るため
/// —— 入出力で単価が違うのが前提)。
public func estimatedCostUSD(usage: Usage, price: ModelPrice) -> Double {
    Double(usage.promptTokens) * price.inputCostPerToken
        + Double(usage.completionTokens) * price.outputCostPerToken
}

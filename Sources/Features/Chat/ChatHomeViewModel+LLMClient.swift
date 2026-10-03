import Foundation
import Services

extension ChatHomeViewModel {
    /// プロバイダ設定を wire adapter に解決する境界。画面再構築の本体をAPI分岐で膨らませず、
    /// 接続先ごとの比較設定を1箇所で適用する。
    static func makeLLMClient(baseURL: URL, apiKey: String, apiStyle: LLMAPIStyle) -> any LLMClient {
        switch apiStyle {
        case .responses:
            OpenAIResponsesClient(baseURL: baseURL, apiKey: apiKey)
        case .chatCompletions:
            OpenAICompatClient(baseURL: baseURL, apiKey: apiKey)
        }
    }
}

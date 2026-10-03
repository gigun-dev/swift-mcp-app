import Foundation

/// 接続先ごとに明示して保存する OpenAI wire API。
public enum LLMAPIStyle: String, Codable, CaseIterable, Equatable, Sendable {
    case responses
    case chatCompletions

    public static func defaultStyle(for baseURL: String) -> LLMAPIStyle {
        URL(string: baseURL)?.host(percentEncoded: false)?.lowercased() == "api.openai.com"
            ? .responses
            : .chatCompletions
    }
}

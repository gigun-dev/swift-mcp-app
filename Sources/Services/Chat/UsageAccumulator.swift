import Kernel

enum UsageAccumulator {
    static func add(_ left: Usage?, _ right: Usage) -> Usage {
        guard let left else { return right }
        let total: Int?
        switch (left.totalTokens, right.totalTokens) {
        case let (left?, right?): total = left + right
        case let (left?, nil): total = left
        case let (nil, right?): total = right
        default: total = nil
        }
        return Usage(
            promptTokens: left.promptTokens + right.promptTokens,
            completionTokens: left.completionTokens + right.completionTokens,
            totalTokens: total
        )
    }
}

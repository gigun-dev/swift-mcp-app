import Foundation
import Kernel
import SwiftUI

/// assistant吹き出し直下に置く、応答速度の控えめな補助表示。
struct ChatPerformanceView: View {
    let metrics: ChatPerformanceMetrics

    var body: some View {
        if !labels.isEmpty {
            Text(labels.joined(separator: " · "))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .accessibilityLabel(labels.joined(separator: "、"))
        }
    }

    private var labels: [String] {
        var result: [String] = []
        if let firstResponse = metrics.firstResponseMilliseconds {
            result.append("\(Int(firstResponse.rounded())) ms first model response")
        }
        if let millisecondsPerToken = metrics.millisecondsPerToken {
            result.append("\(Int(millisecondsPerToken.rounded())) ms/token")
        }
        if let tokensPerSecond = metrics.tokensPerSecond {
            result.append(String(format: "%.2f token/sec", tokensPerSecond))
        }
        if let ttft = metrics.singleRequestTTFTMilliseconds {
            result.append("\(Int(ttft.rounded())) ms LLM TTFT")
        }
        return result
    }
}

import Foundation

/// 失敗span用の属性。本文/URL/userInfoを追加で展開せず、集計可能な分類と単調時計の計測だけを足す。
/// NSErrorのdescriptionをparseするとOS言語や付随URLに依存するためdomain/codeをそのまま分ける。
enum GenerationFailureTelemetry {
    static func fields(
        error: Error,
        requestStartedAt: TimeInterval,
        failedAt: TimeInterval,
        progress: ChatCompletionStreamConsumer.Progress
    ) -> [String: String] {
        let nsError = error as NSError
        var fields = [
            "error.type": "\(nsError.domain):\(nsError.code)",
            "error.domain": nsError.domain,
            "error.code": String(nsError.code),
            "duration_ms": milliseconds(failedAt - requestStartedAt),
            "llm.generation.failure_stage": stage(progress)
        ]
        // responseStartedは成功したSSE headersを表す。HTTP非2xxを「headers未到着」と
        // 呼ぶのは誤りなので、このadapter errorだけ独立させる。再試行判断には使わない。
        if case LLMClientError.httpError(let status, _) = error {
            fields["error.type"] = String(status)
            fields["http.response.status_code"] = String(status)
            fields["llm.generation.failure_stage"] = "http_error"
        }
        if error is CancellationError { fields["error.type"] = "cancelled" }
        if let headers = progress.responseStartedAt {
            fields["llm.generation.response_headers_ms"] = milliseconds(headers - requestStartedAt)
        }
        if let firstOutput = progress.firstOutputAt {
            fields["llm.generation.ttft_ms"] = milliseconds(firstOutput - requestStartedAt)
            if let headers = progress.responseStartedAt {
                fields["llm.generation.headers_to_first_output_ms"] = milliseconds(firstOutput - headers)
            }
        }
        if let firstText = progress.firstTextDeltaAt {
            fields["llm.generation.time_to_first_text_ms"] = milliseconds(firstText - requestStartedAt)
        }
        return fields
    }

    // これはclientイベントの到達段階であり、回線・proxy・providerのどこが原因かの推定ではない。
    // completed受信後にthrowした場合も成功へ変換せず、終端後の障害として区別する。
    private static func stage(_ progress: ChatCompletionStreamConsumer.Progress) -> String {
        if progress.receivedCompletion { return "after_completion" }
        if progress.firstOutputAt != nil { return "streaming_output" }
        if progress.responseStartedAt != nil { return "awaiting_output" }
        return "awaiting_response"
    }

    private static func milliseconds(_ interval: TimeInterval) -> String {
        String(Int(max(0, interval) * 1_000))
    }
}

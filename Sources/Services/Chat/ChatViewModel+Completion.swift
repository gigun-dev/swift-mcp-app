import Foundation
import Kernel

/// 1generationをturn全体のどこで開始したかをまとめる。引数を個別に増やすと、計測項目追加のたびに
/// completion APIが肥大化するため、相関に必要な値だけを値型で渡す。
struct GenerationTimingContext {
    let requestIndex: Int
    let turnStartedAt: TimeInterval
}

@MainActor
extension ChatViewModel {
    func makeCompletionRequest() -> ChatCompletionRequest {
        ChatCompletionRequest(
            model: model,
            messages: wireMessages,
            tools: tools.isEmpty ? nil : tools,
            stream: true,
            reasoningEffort: reasoningEffort
        )
    }

    // swiftlint:disable:next function_body_length
    func receiveCompletion(
        _ request: ChatCompletionRequest,
        assistantIndex: Int,
        turnId: String,
        timing: GenerationTimingContext,
        performance: ChatPerformanceAccumulator
    ) async -> ChatCompletionStreamConsumer.Completion? {
        let requestStartedAt = ProcessInfo.processInfo.systemUptime
        let generationId = UUID().uuidString
        let requestIndex = timing.requestIndex
        let encodedRequest = try? JSONEncoder().encode(request)
        let encodedMessages = try? JSONEncoder().encode(request.messages)
        let inputMessages = encodedMessages.flatMap { String(bytes: $0, encoding: .utf8) } ?? "[]"
        let payloadMetrics = encodedRequest.flatMap {
            try? OpenAICompatClient.payloadMetrics(for: request, encodedBody: $0)
        }
        var startedFields = [
            "turn_id": turnId,
            "generation_id": generationId,
            "llm.generation.request_index": String(requestIndex),
            "llm.generation.phase": requestIndex == 1 ? "initial_decision_or_answer" : "post_tool",
            "llm.generation.turn_elapsed_before_request_ms": String(
                Int(max(0, requestStartedAt - timing.turnStartedAt) * 1_000)
            ),
            "gen_ai.request.model": request.model,
            "gen_ai.input.messages": inputMessages
        ]
        if let payloadMetrics {
            startedFields.merge([
                "llm.request.messages.count": String(payloadMetrics.messageCount),
                "llm.request.system_prompt.utf8_bytes": String(payloadMetrics.systemPromptUTF8Bytes),
                "llm.request.system_messages.json_bytes": String(payloadMetrics.systemMessagesJSONBytes),
                "llm.request.conversation_messages.json_bytes": String(payloadMetrics.conversationMessagesJSONBytes),
                "llm.request.messages.json_bytes": String(payloadMetrics.messagesJSONBytes),
                "llm.request.tools.count": String(payloadMetrics.toolCount),
                "llm.request.tools.json_bytes": String(payloadMetrics.toolsJSONBytes),
                "llm.request.tool_schemas.json_bytes": String(payloadMetrics.toolSchemasJSONBytes),
                "llm.request.tool_schemas.estimated_tokens": String(payloadMetrics.estimatedToolSchemaTokens),
                "llm.request.json_bytes": String(payloadMetrics.requestJSONBytes)
            ]) { _, new in new }
        }
        telemetry.event("llm.generation.started", fields: startedFields, level: .info)
        do {
            let completion = try await ChatCompletionStreamConsumer.consume(llm.stream(request)) { text in
                turns[assistantIndex].text = text
            }
            performance.record(
                requestStartedAt: requestStartedAt,
                firstOutputAt: completion.firstOutputAt,
                completedAt: completion.completedAt,
                usage: completion.usage
            )
            let outputMessage = ChatMessage(
                role: .assistant,
                content: completion.text.isEmpty ? nil : completion.text,
                toolCalls: completion.toolCalls.isEmpty ? nil : completion.toolCalls
            )
            let encodedOutput = try? JSONEncoder().encode([outputMessage])
            let outputMessages = encodedOutput.flatMap { String(bytes: $0, encoding: .utf8) } ?? "[]"
            var fields = [
                "turn_id": turnId,
                "generation_id": generationId,
                "llm.generation.request_index": String(requestIndex),
                "llm.generation.phase": requestIndex == 1 ? "initial_decision_or_answer" : "post_tool",
                "gen_ai.output.messages": outputMessages,
                "gen_ai.response.finish_reason": completion.finishReason.wireValue,
                "llm.generation.tool_call_count": String(completion.toolCalls.count),
                "llm.generation.response_kind": completion.toolCalls.isEmpty ? "text" : "tool_calls",
                "duration_ms": String(Int((completion.completedAt - requestStartedAt) * 1_000))
            ]
            if let usage = completion.usage {
                fields["gen_ai.usage.input_tokens"] = String(usage.promptTokens)
                fields["gen_ai.usage.output_tokens"] = String(usage.completionTokens)
                if let cachedTokens = usage.promptTokensDetails?.cachedTokens {
                    fields["llm.usage.cached_prompt_tokens"] = String(cachedTokens)
                    fields["llm.usage.uncached_prompt_tokens"] = String(max(0, usage.promptTokens - cachedTokens))
                }
            }
            if let responseStartedAt = completion.responseStartedAt {
                fields["llm.generation.response_headers_ms"] = String(
                    Int(max(0, responseStartedAt - requestStartedAt) * 1_000)
                )
            }
            if let firstOutputAt = completion.firstOutputAt {
                fields["llm.generation.ttft_ms"] = String(Int((firstOutputAt - requestStartedAt) * 1_000))
                if let responseStartedAt = completion.responseStartedAt {
                    fields["llm.generation.headers_to_first_output_ms"] = String(
                        Int(max(0, firstOutputAt - responseStartedAt) * 1_000)
                    )
                }
            }
            if let firstTextDeltaAt = completion.firstTextDeltaAt {
                fields["llm.generation.time_to_first_text_ms"] = String(
                    Int(max(0, firstTextDeltaAt - requestStartedAt) * 1_000)
                )
            }
            telemetry.event("llm.generation.finished", fields: fields, level: .info)
            return completion
        } catch is CancellationError {
            telemetry.event("llm.generation.error", fields: [
                "turn_id": turnId, "generation_id": generationId, "error": "cancelled"
            ], level: .error)
            return nil
        } catch {
            errorMessage = "LLM ストリームに失敗しました: \(error)"
            telemetry.event("llm.generation.error", fields: [
                "turn_id": turnId, "generation_id": generationId, "error": String(reflecting: error)
            ], level: .error)
            return nil
        }
    }

    func recordCompletion(
        _ completion: ChatCompletionStreamConsumer.Completion,
        assistantIndex: Int,
        turnId: String
    ) {
        traceSink?.emit(.llmCompleted(
            turnId: turnId,
            finishReason: completion.finishReason.wireValue,
            usage: completion.usage
        ))
        if let usage = completion.usage {
            lastUsage = usage
            cumulativeUsage = UsageAccumulator.add(cumulativeUsage, usage)
            turns[assistantIndex].usage = usage
        }
        wireMessages.append(ChatMessage(
            role: .assistant,
            content: completion.text.isEmpty ? nil : completion.text,
            toolCalls: completion.toolCalls.isEmpty ? nil : completion.toolCalls
        ))
    }

    func recordToolBatch(_ batch: ToolCallRunner.Batch, assistantIndex: Int) {
        turns[assistantIndex].toolSteps = batch.steps
        turns[assistantIndex].cards.append(contentsOf: batch.cards)
        wireMessages.append(contentsOf: batch.wireMessages)
    }
}

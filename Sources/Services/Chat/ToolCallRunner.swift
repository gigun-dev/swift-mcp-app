import Foundation
import Kernel
import OSLog

/// 1回のLLM応答に含まれる複数のtool callを並行実行し、表示・wire・カード用の結果へ変換する。
///
/// ChatViewModelは会話状態の遷移だけを担当し、MCP実行、結果の安定ソート、カード判定はここに閉じ込める。
struct ToolCallRunner: Sendable {
    struct Batch: Sendable {
        let steps: [ToolCallStep]
        let cards: [CardEmbed]
        let wireMessages: [ChatMessage]
    }

    enum ArgumentsDecodeResult: Equatable {
        case value(JSONValue)
        case invalid(String)
    }

    private struct Execution: Sendable {
        let index: Int
        let toolCallId: String
        let toolName: String
        let content: String
        let failed: Bool
        let result: JSONValue?
        let arguments: JSONValue?
    }

    private struct ExecutionContext: Sendable {
        let executor: any MCPToolExecuting
        let traceSink: (any TraceSink)?
        let turnId: String
    }

    private static let logger = Logger(subsystem: "dev.gigun.mcphost", category: "chat-diag")
    private let executor: any MCPToolExecuting
    private let resourceURIs: [String: String]
    /// ChatViewModel 構築時点の wire tool名 → ユーザー表示名。長名は wire 上で hash 短縮され
    /// slug を逆算できないため、完全な wire 名で引いて ToolCallStep へ当時値を焼き付ける。
    private let serverNames: [String: String]
    private let originalToolNames: [String: String]
    private let traceSink: (any TraceSink)?

    init(
        executor: any MCPToolExecuting,
        resourceURIs: [String: String],
        serverNames: [String: String],
        originalToolNames: [String: String],
        traceSink: (any TraceSink)?
    ) {
        self.executor = executor
        self.resourceURIs = resourceURIs
        self.serverNames = serverNames
        self.originalToolNames = originalToolNames
        self.traceSink = traceSink
    }

    func runningSteps(for calls: [ToolCall]) -> [ToolCallStep] {
        calls.map {
            return ToolCallStep(
                toolName: $0.function.name,
                originalToolName: originalToolNames[$0.function.name],
                serverName: serverNames[$0.function.name],
                state: .running,
                argumentsJSON: $0.function.arguments
            )
        }
    }

    func run(_ calls: [ToolCall], turnId: String) async -> Batch {
        Self.logger.notice("tool calls開始 count=\(calls.count, privacy: .public)")
        let results = await executeConcurrently(calls, turnId: turnId)
        Self.logger.notice("tool calls完了 count=\(results.count, privacy: .public)")

        return Batch(
            steps: makeFinishedSteps(calls: calls, results: results),
            cards: makeCards(results),
            wireMessages: makeWireMessages(results)
        )
    }

    private func executeConcurrently(_ calls: [ToolCall], turnId: String) async -> [Execution] {
        let context = ExecutionContext(executor: executor, traceSink: traceSink, turnId: turnId)
        return await withTaskGroup(of: Execution.self) { group in
            for (index, call) in calls.enumerated() {
                group.addTask {
                    await Self.execute(
                        call: call,
                        index: index,
                        context: context
                    )
                }
            }
            var collected: [Execution] = []
            for await result in group {
                collected.append(result)
            }
            return collected
        }
    }

    private func makeFinishedSteps(calls: [ToolCall], results: [Execution]) -> [ToolCallStep] {
        var steps = runningSteps(for: calls)
        for result in results {
            steps[result.index].state = result.failed ? .failed : .done
            steps[result.index].resultJSON = result.content
        }
        return steps
    }

    private func makeCards(_ results: [Execution]) -> [CardEmbed] {
        results.sorted(by: { $0.index < $1.index }).compactMap { result in
            guard !result.failed,
                  result.result?["isError"]?.boolValue != true,
                  let uri = Self.resourceURI(
                      forResult: result.result,
                      toolName: result.toolName,
                      fallback: resourceURIs
                  )
            else { return nil }

            return CardEmbed(
                toolName: result.toolName,
                resourceUri: uri,
                snapshotHTML: nil,
                structuredContent: result.result,
                arguments: result.arguments
            )
        }
    }

    private func makeWireMessages(_ results: [Execution]) -> [ChatMessage] {
        results.sorted(by: { $0.toolCallId < $1.toolCallId }).map { result in
            ChatMessage(
                role: .tool,
                content: result.content,
                toolCallId: result.toolCallId,
                name: result.toolName
            )
        }
    }

    static func resourceURI(
        forResult result: JSONValue?,
        toolName: String,
        fallback: [String: String]
    ) -> String? {
        if let meta = result?["_meta"] {
            if let uri = meta["ui"]?["resourceUri"]?.stringValue {
                return uri
            }
            if let uri = meta["ui/resourceUri"]?.stringValue {
                return uri
            }
        }
        return fallback[toolName]
    }

    static func decodeArguments(_ raw: String) -> ArgumentsDecodeResult {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .value(.object([:])) }
        guard let value = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)) else {
            return .invalid("tool call arguments が JSON として不正: \(String(trimmed.prefix(200)))")
        }
        return .value(value)
    }

    private static func execute(
        call: ToolCall,
        index: Int,
        context: ExecutionContext
    ) async -> Execution {
        switch decodeArguments(call.function.arguments) {
        case .invalid(let message):
            return Execution(
                index: index,
                toolCallId: call.id,
                toolName: call.function.name,
                content: message,
                failed: true,
                result: nil,
                arguments: nil
            )
        case .value(let arguments):
            return await executeValid(
                call: call,
                index: index,
                arguments: arguments,
                context: context
            )
        }
    }

    private static func executeValid(
        call: ToolCall,
        index: Int,
        arguments: JSONValue,
        context: ExecutionContext
    ) async -> Execution {
        context.traceSink?.emit(.toolCallStarted(
            turnId: context.turnId,
            callId: call.id,
            name: call.function.name,
            arguments: arguments
        ))
        let startedAt = Date()
        do {
            let result = try await context.executor.callTool(name: call.function.name, arguments: arguments)
            let data = (try? JSONEncoder().encode(result)) ?? Data("null".utf8)
            emitFinished(
                context,
                call: call,
                startedAt: startedAt,
                isError: result["isError"]?.boolValue == true,
                resultBytes: data.count
            )
            return Execution(
                index: index,
                toolCallId: call.id,
                toolName: call.function.name,
                content: String(data: data, encoding: .utf8) ?? "null",
                failed: false,
                result: result,
                arguments: arguments
            )
        } catch {
            emitFinished(
                context,
                call: call,
                startedAt: startedAt,
                isError: true,
                resultBytes: 0
            )
            return Execution(
                index: index,
                toolCallId: call.id,
                toolName: call.function.name,
                content: "ツール実行エラー: \(error)",
                failed: true,
                result: nil,
                arguments: arguments
            )
        }
    }

    private static func emitFinished(
        _ context: ExecutionContext,
        call: ToolCall,
        startedAt: Date,
        isError: Bool,
        resultBytes: Int
    ) {
        context.traceSink?.emit(.toolCallFinished(
            turnId: context.turnId,
            callId: call.id,
            isError: isError,
            resultBytes: resultBytes,
            durationMs: Int(Date().timeIntervalSince(startedAt) * 1000)
        ))
    }
}

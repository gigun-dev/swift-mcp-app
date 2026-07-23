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

    // ToolCallRunner+PermissionGate.swift(別ファイルの extension)からも参照するため internal。
    struct Execution: Sendable {
        let index: Int
        let toolCallId: String
        let toolName: String
        let content: String
        let failed: Bool
        let result: JSONValue?
        let arguments: JSONValue?
    }

    // ToolCallRunner+PermissionGate.swift からも参照するため internal(nested type の可視性)。
    struct ExecutionContext: Sendable {
        let executor: any MCPToolExecuting
        let traceSink: (any TraceSink)?
        let turnId: String
        // R4 許可ゲート: static な execute から参照するため、Runner のインスタンス状態
        // (annotations・serverURL・表示名マップ・store)をここへ束ねて運ぶ。
        let permissionStore: any ToolPermissionResolving
        let annotationsByTool: [String: ToolAnnotations]
        let serverURLsByTool: [String: URL]
        let serverNamesByTool: [String: String]
        let originalToolNamesByTool: [String: String]
        /// 確認 UI への問い合わせ(Features が実装を注入)。Runner は UI を知らない
        /// (traceSink と同じ依存注入の流儀)。並行 tool call ごとに独立して await される。
        let confirm: @Sendable (ToolCallConfirmationRequest) async -> ToolCallConfirmationResponse
    }

    private static let logger = Logger(subsystem: "dev.gigun.mcphost", category: "chat-diag")
    private let executor: any MCPToolExecuting
    private let resourceURIs: [String: String]
    /// ChatViewModel 構築時点の wire tool名 → ユーザー表示名。長名は wire 上で hash 短縮され
    /// slug を逆算できないため、完全な wire 名で引いて ToolCallStep へ当時値を焼き付ける。
    private let serverNames: [String: String]
    private let originalToolNames: [String: String]
    /// wire tool 名からカード生成元を復元するための安定 provenance。UI 層が slug を推測せず、
    /// 履歴カードを同じ登録・同じ endpoint にだけ再接続するため CardEmbed へ焼き付ける。
    private let serverIDs: [String: UUID]
    private let serverURLs: [String: URL]
    private let traceSink: (any TraceSink)?
    /// R4 許可ゲートの判定材料: wire tool 名 → annotations(untrusted hint)。ToolConversion で
    /// ToolDefinition に載せた annotations を ChatViewModel が wire 名キーで畳んで渡す。空 = 未申告扱い。
    private let annotationsByTool: [String: ToolAnnotations]
    /// per-tool 決定の永続化ストア。既定は AllowAllToolPermissionStore(注入省略時は従来どおり即実行)。
    private let permissionStore: any ToolPermissionResolving

    init(
        executor: any MCPToolExecuting,
        resourceURIs: [String: String],
        serverNames: [String: String],
        originalToolNames: [String: String],
        serverIDs: [String: UUID],
        serverURLs: [String: URL],
        traceSink: (any TraceSink)?,
        annotationsByTool: [String: ToolAnnotations] = [:],
        permissionStore: any ToolPermissionResolving = AllowAllToolPermissionStore()
    ) {
        self.executor = executor
        self.resourceURIs = resourceURIs
        self.serverNames = serverNames
        self.originalToolNames = originalToolNames
        self.serverIDs = serverIDs
        self.serverURLs = serverURLs
        self.traceSink = traceSink
        self.annotationsByTool = annotationsByTool
        self.permissionStore = permissionStore
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

    /// - Parameter confirm: 許可ゲートが「確認必須」と判定したときに呼ぶ問い合わせ。既定は
    ///   「今回だけ許可」を即返す no-op(注入省略時は従来どおり実行——AllowAllStore との組で二重に安全)。
    ///   本番は ChatViewModel が確認 UI へ橋渡しする実装を渡す。
    func run(
        _ calls: [ToolCall],
        turnId: String,
        confirm: @escaping @Sendable (ToolCallConfirmationRequest) async -> ToolCallConfirmationResponse
            = { _ in .allowOnce }
    ) async -> Batch {
        Self.logger.notice("tool calls開始 count=\(calls.count, privacy: .public)")
        let results = await executeConcurrently(calls, turnId: turnId, confirm: confirm)
        Self.logger.notice("tool calls完了 count=\(results.count, privacy: .public)")

        return Batch(
            steps: makeFinishedSteps(calls: calls, results: results),
            cards: makeCards(results),
            wireMessages: makeWireMessages(results)
        )
    }

    private func executeConcurrently(
        _ calls: [ToolCall],
        turnId: String,
        confirm: @escaping @Sendable (ToolCallConfirmationRequest) async -> ToolCallConfirmationResponse
    ) async -> [Execution] {
        let context = ExecutionContext(
            executor: executor,
            traceSink: traceSink,
            turnId: turnId,
            permissionStore: permissionStore,
            annotationsByTool: annotationsByTool,
            serverURLsByTool: serverURLs,
            serverNamesByTool: serverNames,
            originalToolNamesByTool: originalToolNames,
            confirm: confirm
        )
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
}

// 結果組み立て(steps/cards/wire)と素通しユーティリティ。primary 宣言の type body を膨らませないよう
// 同一ファイルの extension へ分ける(private メンバは同一ファイルなのでそのまま参照できる)。
extension ToolCallRunner {
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
                serverID: serverIDs[result.toolName],
                serverURL: serverURLs[result.toolName],
                originalToolName: originalToolNames[result.toolName],
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
        // R4 許可ゲート(HITL): callTool の副作用が起きる前に確認要否を判定する(詳細は下の
        // permissionGateDenial・正典: caldav docs/modeling/15 §A)。拒否なら failed Execution を返して終了。
        if let denial = await permissionGateDenial(call: call, index: index, arguments: arguments, context: context) {
            return denial
        }

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

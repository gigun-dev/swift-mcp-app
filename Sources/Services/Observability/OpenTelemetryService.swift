import Foundation
import Kernel
import OpenTelemetryApi
import OpenTelemetrySdk
import OpenTelemetryProtocolExporterHttp

/// 任意のOTLP/HTTP endpointへtracing signalを送る設定。
/// 認証やベンダー固有headerはcomposition rootで組み立て、このadapterは解釈せず渡す。
public struct OpenTelemetryConfiguration: Sendable, Equatable {
    public let endpoint: URL
    public let headers: [(String, String)]
    public let resourceAttributes: [String: String]

    public init(endpoint: URL, headers: [(String, String)] = [], resourceAttributes: [String: String] = [:]) {
        self.endpoint = endpoint
        self.headers = headers
        self.resourceAttributes = resourceAttributes
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.endpoint == rhs.endpoint
            && lhs.resourceAttributes == rhs.resourceAttributes
            && lhs.headers.map { "\($0.0):\($0.1)" } == rhs.headers.map { "\($0.0):\($0.1)" }
    }
}

/// 既存の TelemetryPort / TraceSink を OTLP span へ写像する唯一の adapter。
/// SDK 型をこのファイルより上へ漏らさないため、チャットやカードは文字列イベントを発火するだけでよい。
public final class OpenTelemetryService: TelemetryPort, TraceSink, @unchecked Sendable {
    private let provider: TracerProviderSdk
    private let tracer: any Tracer
    private let lock = NSLock()
    private var turnSpans: [String: any Span] = [:]
    private var generationSpans: [String: any Span] = [:]
    private var toolSpans: [String: any Span] = [:]
    private var cardSpans: [String: any Span] = [:]
    private var correlationContextsByTurnID: [String: String] = [:]

    public init(configuration: OpenTelemetryConfiguration) {
        let exporter = OtlpHttpTraceExporter(
            endpoint: configuration.endpoint,
            config: .init(
                compression: .gzip,
                headers: configuration.headers,
                exportAsJson: false
            ),
            // アプリ設定のheaderを常に使い、実行環境のOTEL_EXPORTER_OTLP_HEADERSで
            // 意図せず上書きされないようenv由来headerを無効化する。
            envVarHeaders: nil
        )
        let processor = BatchSpanProcessor(spanExporter: exporter)
        provider = TracerProviderBuilder()
            .with(resource: Self.resource(for: configuration))
            .with(sampler: Samplers.alwaysOn)
            .add(spanProcessor: processor)
            .build()
        tracer = provider.get(instrumentationName: "dev.gigun.mcphost", instrumentationVersion: "1")
    }

    // Resource attributes apply equally to chat, generation, tool and card spans.
    // The default keeps shipping behaviour; verification can identify itself without vendor-specific fields.
    static func resource(for configuration: OpenTelemetryConfiguration) -> OpenTelemetrySdk.Resource {
        let attributes = configuration.resourceAttributes.mapValues(AttributeValue.string)
        return OpenTelemetrySdk.Resource(
            attributes: ["service.name": .string("swift-mcp-app")].merging(attributes) { _, new in new }
        )
    }

    public func emit(_ event: ChatTraceEvent) {
        lock.withLock {
            switch event {
            case .turnStarted(let chatID, let turnID, let model):
                let span = tracer.spanBuilder(spanName: "chat.turn").setNoParent().startSpan()
                span.setAttribute(key: "gen_ai.operation.name", value: "invoke_agent")
                span.setAttribute(key: "gen_ai.conversation.id", value: chatID)
                span.setAttribute(key: "chat.turn.id", value: turnID)
                span.setAttribute(key: "gen_ai.request.model", value: model)
                turnSpans[turnID] = span
                correlationContextsByTurnID[turnID] = Self.traceParent(from: span.context)
            case .llmCompleted(let turnID, let finishReason, let usage):
                guard let span = turnSpans[turnID] else { return }
                span.addEvent(name: "llm.completed", attributes: usageAttributes(usage).merging([
                    "gen_ai.response.finish_reasons": .string(finishReason)
                ]) { _, new in new })
            case .toolCallStarted(let turnID, let callID, let name, let arguments):
                let builder = tracer.spanBuilder(spanName: "mcp.tool \(name)").setSpanKind(spanKind: .client)
                if let parent = turnSpans[turnID] { builder.setParent(parent) } else { builder.setNoParent() }
                let span = builder.startSpan()
                span.setAttribute(key: "gen_ai.operation.name", value: "execute_tool")
                span.setAttribute(key: "gen_ai.tool.call.arguments", value: json(arguments))
                span.setAttribute(key: "gen_ai.tool.name", value: name)
                span.setAttribute(key: "gen_ai.tool.call.id", value: callID)
                span.setAttribute(key: "mcp.tool.name", value: name)
                span.setAttribute(key: "mcp.tool.call_id", value: callID)
                toolSpans[callID] = span
            case .toolCallFinished(_, let callID, let isError, let resultBytes, let durationMs):
                guard let span = toolSpans.removeValue(forKey: callID) else { return }
                span.setAttribute(key: "mcp.result.bytes", value: resultBytes)
                span.setAttribute(key: "mcp.duration_ms", value: durationMs)
                span.status = isError ? .error(description: "MCP tool returned an error") : .ok
                span.end()
            case .turnSettled(let turnID, let iterations, let usage):
                guard let span = turnSpans.removeValue(forKey: turnID) else { return }
                span.setAttribute(key: "chat.iterations", value: iterations)
                span.setAttributes(usageAttributes(usage))
                // 最大反復でoutputがErrorを記録済みなら上書きしない。個別toolの失敗は
                // 親へ伝播させず、その後モデルが回復して.stopに到達した会話はOKにする。
                if span.status == .unset { span.status = .ok }
                span.end()
                correlationContextsByTurnID.removeValue(forKey: turnID)
            }
        }
    }

    public func correlationContext(for operationID: String) -> String? {
        lock.withLock { correlationContextsByTurnID[operationID] }
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func event(_ name: String, fields: [String: String], level: TelemetryLevel) {
        lock.withLock {
            let activeParent = fields["turn_id"].flatMap { turnSpans[$0] }
            let persistedParent = fields["telemetry.trace_parent"].flatMap(Self.spanContext(from:))
            switch name {
            case "chat.turn.input":
                activeParent?.setAttribute(key: "chat.user_input", value: fields["input"] ?? "")
            case "chat.turn.output":
                activeParent?.setAttribute(key: "chat.assistant_output", value: fields["output"] ?? "")
                if level == .error {
                    activeParent?.status = .error(description: fields["error"] ?? "Chat turn failed")
                }
            case "chat.turn.aborted":
                guard let id = fields["turn_id"], let span = turnSpans.removeValue(forKey: id) else { return }
                set(fields, on: span)
                span.status = .error(description: fields["error"] ?? "Chat turn aborted")
                span.end()
                correlationContextsByTurnID.removeValue(forKey: id)
            case "llm.generation.started":
                guard let id = fields["generation_id"] else { return }
                let builder = tracer.spanBuilder(spanName: "llm.generation").setSpanKind(spanKind: .client)
                if let activeParent { builder.setParent(activeParent) } else { builder.setNoParent() }
                let span = builder.startSpan()
                span.setAttribute(key: "gen_ai.operation.name", value: "chat")
                set(fields, on: span)
                generationSpans[id] = span
            case "llm.generation.finished", "llm.generation.error":
                guard let id = fields["generation_id"],
                      let span = generationSpans.removeValue(forKey: id) else { return }
                set(fields, on: span)
                span.status = name.hasSuffix("error") ? .error(description: fields["error"] ?? "LLM error") : .ok
                span.end()
            case "mcp.tool.output":
                guard let id = fields["call_id"], let span = toolSpans[id] else { return }
                span.setAttribute(key: "gen_ai.tool.call.result", value: fields["output"] ?? "")
            case "card.render.started":
                guard let id = fields["card_id"] else { return }
                let span = tracer.spanBuilder(spanName: "card.render").setNoParent().startSpan()
                set(fields, on: span)
                cardSpans[id] = span
            case "card.render.finished", "card.render.error":
                guard let id = fields["card_id"], let span = cardSpans.removeValue(forKey: id) else { return }
                set(fields, on: span)
                span.status = name.hasSuffix("error")
                    ? .error(description: fields["error"] ?? "Card render error") : .ok
                span.end()
            default:
                let builder = tracer.spanBuilder(spanName: name)
                if let activeParent { builder.setParent(activeParent) } else if let persistedParent {
                    builder.setParent(persistedParent)
                } else { builder.setNoParent() }
                let span = builder.startSpan()
                set(fields, on: span)
                if level == .error { span.status = .error(description: fields["error"] ?? name) }
                span.end()
            }
        }
    }

    private func set(_ fields: [String: String], on span: any Span) {
        for (key, value) in fields where key != "telemetry.trace_parent" {
            span.setAttribute(key: key, value: value)
        }
    }

    private static func traceParent(from context: SpanContext) -> String {
        let flags = context.isSampled ? "01" : "00"
        return "00-\(context.traceId.hexString)-\(context.spanId.hexString)-\(flags)"
    }

    private static func spanContext(from traceParent: String) -> SpanContext? {
        let parts = traceParent.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        let traceID = TraceId(fromHexString: String(parts[1]))
        let spanID = SpanId(fromHexString: String(parts[2]))
        guard traceID.isValid, spanID.isValid else { return nil }
        let flags = UInt8(parts[3], radix: 16) ?? 0
        return SpanContext.createFromRemoteParent(
            traceId: traceID,
            spanId: spanID,
            traceFlags: TraceFlags(fromByte: flags),
            traceState: TraceState()
        )
    }

    private func usageAttributes(_ usage: Usage?) -> [String: AttributeValue] {
        guard let usage else { return [:] }
        var attributes: [String: AttributeValue] = [
            "gen_ai.usage.input_tokens": .int(usage.promptTokens),
            "gen_ai.usage.output_tokens": .int(usage.completionTokens)
        ]
        if let cachedTokens = usage.promptTokensDetails?.cachedTokens {
            attributes["llm.usage.cached_prompt_tokens"] = .int(cachedTokens)
            attributes["llm.usage.uncached_prompt_tokens"] = .int(max(0, usage.promptTokens - cachedTokens))
        }
        return attributes
    }

    private func json(_ value: JSONValue) -> String {
        guard let data = try? JSONEncoder().encode(value) else { return "null" }
        return String(bytes: data, encoding: .utf8) ?? "null"
    }
}

/// OSLog と OTLP の両方を保つための動的 router。設定保存後も既存 ChatViewModel の参照を差し替えずに済む。
public final class TelemetryRouter: TelemetryPort, TraceSink, @unchecked Sendable {
    private let lock = NSLock()
    private let localTelemetry: any TelemetryPort
    private let localTrace: any TraceSink
    private var remote: OpenTelemetryService?

    public init(localTelemetry: any TelemetryPort = OSLogTelemetry(), localTrace: any TraceSink = OSLogTraceSink()) {
        self.localTelemetry = localTelemetry
        self.localTrace = localTrace
    }

    public func configure(_ configuration: OpenTelemetryConfiguration?) {
        lock.withLock { remote = configuration.map(OpenTelemetryService.init) }
    }

    public func event(_ name: String, fields: [String: String], level: TelemetryLevel) {
        localTelemetry.event(name, fields: fields, level: level)
        lock.withLock { remote }?.event(name, fields: fields, level: level)
    }

    public func emit(_ event: ChatTraceEvent) {
        localTrace.emit(event)
        lock.withLock { remote }?.emit(event)
    }

    public func correlationContext(for operationID: String) -> String? {
        lock.withLock { remote }?.correlationContext(for: operationID)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}

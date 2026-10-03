// OpenAI 互換 chat/completions の第一 LLM アダプタ(設計 §2)。
//
// 責務: ChatCompletionRequest を OpenAI 互換エンドポイントへ POST(stream:true)し、
// 返ってくる SSE を LLMEvent(textDelta* → completed 1回)へ翻訳する。base URL / API キー /
// モデルは注入(BYOK。CLAUDE.md ビジョン1 の「LLM 呼び出しはエンドポイント1箇所に抽象」)。
//
// I/O とパースの分離(T2 指示 B): ネットワーク(URLSession.bytes による行読み)はここ、
// SSE の行→data 抽出は SSELineParser(純関数)、tool_calls delta の蓄積は Kernel の
// ToolCallAccumulator(T1)に委ねる。SSE パーサ内で tool_calls 連結を再実装しない。
import Foundation
import Kernel
import OSLog

struct LLMRequestPayloadMetrics: Equatable {
    let messageCount: Int
    let systemPromptUTF8Bytes: Int
    let systemMessagesJSONBytes: Int
    let conversationMessagesJSONBytes: Int
    let messagesJSONBytes: Int
    let toolCount: Int
    let toolsJSONBytes: Int
    let toolSchemasJSONBytes: Int
    let estimatedToolSchemaTokens: Int
    let requestJSONBytes: Int
}

/// OpenAI互換 `GET /v1/models` の標準的な共通部分。
public struct OpenAICompatibleModel: Decodable, Identifiable, Sendable, Equatable {
    public let id: String
    public let ownedBy: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case ownedBy = "owned_by"
    }
}

private struct OpenAICompatibleModelList: Decodable {
    let data: [OpenAICompatibleModel]
}

private struct SSECompletionAccumulator {
    var toolCalls = ToolCallAccumulator()
    var finishReason: FinishReason?
    var usage: Usage?
    var emittedToolOutputStarted = false

    mutating func handle(
        payload: String,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) throws -> Bool {
        if payload == "[DONE]" { return true }
        let chunk = try JSONDecoder().decode(ChatCompletionChunk.self, from: Data(payload.utf8))
        if let chunkUsage = chunk.usage { usage = chunkUsage }
        for choice in chunk.choices {
            if let content = choice.delta.content, !content.isEmpty {
                continuation.yield(.textDelta(content))
            }
            if let calls = choice.delta.toolCalls {
                if !calls.isEmpty, !emittedToolOutputStarted {
                    continuation.yield(.outputStarted)
                    emittedToolOutputStarted = true
                }
                toolCalls.accumulate(calls)
            }
            if let reason = choice.finishReason { finishReason = reason }
        }
        return false
    }
}

/// OpenAI 互換 SSE アダプタ。
///
/// actor でなく struct + Sendable: 保持する状態は不変(baseURL/apiKey/urlSession)だけで、
/// ストリーム実行中の可変状態(パーサ・アキュムレータ)は stream(_:) 内のローカルに閉じる。
/// 共有可変状態が無いので値型で並行安全にできる(actor の直列化オーバーヘッドも要らない)。
public struct OpenAICompatClient: LLMClient {
    private static let requestLogger = Logger(subsystem: "dev.gigun.mcphost", category: "llm-request-size")
    private let baseURL: URL
    private let apiKey: String
    private let urlSession: URLSession

    /// - Parameters:
    ///   - baseURL: OpenAI互換の `/v1` base URL、または chat/completions の完全URL。
    ///     `/v1` と `/v1/` は通信時に `/v1/chat/completions` へ正規化する。それ以外の
    ///     独自パスは、プロバイダ互換性を壊さないよう入力どおり利用する。
    ///   - apiKey: `Authorization: Bearer <key>` に載せる API キー。
    ///   - urlSession: 注入可能(テストで差し替え)。既定 nil のときは明示タイムアウト付きの
    ///     専用セッションを組む(下 defaultSession)。テストは自前のスタブ session を渡すので影響なし。
    public init(baseURL: URL, apiKey: String, urlSession: URLSession? = nil) {
        self.baseURL = Self.chatCompletionsURL(from: baseURL)
        self.apiKey = apiKey
        self.urlSession = urlSession ?? Self.defaultSession()
    }

    /// OpenAI SDK と同じ `/v1` base URL 表記を、このクライアントがPOSTする完全URLへ変換する。
    public static func chatCompletionsURL(from baseURL: URL) -> URL {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let path = components?.percentEncodedPath ?? baseURL.path
        let trimmedPath = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        guard trimmedPath.hasSuffix("/v1") else { return baseURL }
        components?.percentEncodedPath = trimmedPath + "/chat/completions"
        return components?.url ?? baseURL
    }

    /// chat/completions URL または `/v1` base URLから、標準のmodels URLを求める。
    public static func modelsURL(from baseURL: URL) -> URL {
        let chatURL = chatCompletionsURL(from: baseURL)
        var components = URLComponents(url: chatURL, resolvingAgainstBaseURL: false)
        let suffix = "/chat/completions"
        let path = components?.percentEncodedPath ?? chatURL.path
        guard path.hasSuffix(suffix) else { return baseURL.appendingPathComponent("models") }
        components?.percentEncodedPath = String(path.dropLast(suffix.count)) + "/models"
        return components?.url ?? baseURL.appendingPathComponent("models")
    }

    /// OpenAI互換のモデル一覧を取得する。未知のプロバイダ拡張フィールドは無視する。
    public func listModels() async throws -> [OpenAICompatibleModel] {
        var request = URLRequest(url: Self.modelsURL(from: baseURL))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            let body = String(bytes: data, encoding: .utf8) ?? ""
            throw LLMClientError.httpError(statusCode: http.statusCode, body: body)
        }
        return try JSONDecoder().decode(OpenAICompatibleModelList.self, from: data).data
    }

    /// 明示タイムアウト付きの既定セッション(実機 FB 2026-07-17「送信後ずっと無音」への恒久対処)。
    ///
    /// 【なぜ ChatViewModel の消費側でなくここ(ネットワーク層)にタイムアウトを置くか】
    /// 無応答の実体は URLSession が「追加データを待ち続ける」状態。URLSessionConfiguration の
    /// `timeoutIntervalForRequest` は **追加データ到着ごとにリセットされるイベント間タイムアウト**で、
    /// まさに「delta が N 秒来なければ打ち切る」の意味に一致する。ここで設定すれば URLSession.bytes の
    /// for-await が timeout エラーで throw → consumeSSE が投げ返し → ChatViewModel.send の
    /// catch(既存のエラー経路)が errorMessage に載せて赤字表示する。消費側で自前の per-event
    /// タイムアウトを組む(AsyncThrowingStream のイテレータを race させる)より、標準機構に乗る方が
    /// 単純で確実(iterator を並行タスクで race するのは Sendable/再入の綱渡りになる)。
    /// 中立性: これは HTTP/SSE トランスポートの都合なので OpenAI 互換アダプタ内に閉じてよい
    /// (LLMClient プロトコルにタイムアウトの概念を持ち込まない)。
    ///
    /// 既定 `.shared` も実は timeoutIntervalForRequest=60 を持つが、それは暗黙のプロセス共有既定で
    /// あり、この値に依存していることがコードから読み取れない。専用セッションで**明示**し、
    /// 意図(無音ハングを 60s で切る)をコードに刻む。
    private static func defaultSession() -> URLSession {
        let config = URLSessionConfiguration.default
        // イベント間(追加データ待ち)の無応答タイムアウト。SSE は正常時 delta が刻々届くので、
        // 60s も新データが来なければ回線ハング/プロバイダ停止とみなして打ち切る。正常にストリームが
        // 流れている限りデータ到着ごとにリセットされるので誤発火しない(= inter-event timeout)。
        config.timeoutIntervalForRequest = 60
        // リクエスト全体の上限。ツール1周の補完は通常数秒〜十数秒だが、長考モデルや長い tool-use
        // ターンを考慮して 300s に置く(全体が固まり続けるのを最終的に断ち切る保険)。
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }

    public func stream(_ request: ChatCompletionRequest) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            // Task で非同期処理を回し、AsyncThrowingStream の continuation に yield する。
            // onTermination で Task をキャンセルし、消費側が break/中断したら通信も止める
            // (URLSession.bytes はキャンセルで例外終了する)。
            let task = Task {
                do {
                    try await self.runStream(request, into: continuation)
                } catch is CancellationError {
                    // 消費側の打ち切り。エラーとして投げず、静かに終端する
                    // (呼び出し側は onTermination 経由で意図的に止めているため)。
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - 実処理

    /// 1回のリクエストを送り、SSE を読み切って completed を1回 yield する。
    /// stream_options 未対応プロバイダの 400 に対し、stream_options 無しで1回だけリトライする
    /// (設計 §6。OpenAI 公式は対応済みなので実際には走らないが、中立性のための保険)。
    private func runStream(
        _ request: ChatCompletionRequest,
        into continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        // ホストは常に stream:true + include_usage を強制する(呼び出し側の設定漏れを防ぐ・§2/§6)。
        var body = request
        body.stream = true
        body.streamOptions = .init(includeUsage: true)

        let (bytes, response) = try await urlSession.bytes(for: makeURLRequest(body))

        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            // 非 2xx。ボディを読んでエラーに含める(検証・デバッグのため・T2 指示 B)。
            let errorBody = try await Self.collectBody(bytes)

            // stream_options を付けたことが原因の 400 と推定できる場合、外して1回だけ再試行。
            // 400 かどうかだけで判定する(未知パラメータ 400 のワイヤ文言はプロバイダ依存で
            // 当てにできないため、素朴に「stream_options を付けた最初の 400」で1回だけ引き返す)。
            if http.statusCode == 400 {
                var retryBody = body
                retryBody.streamOptions = nil
                let (retryBytes, retryResponse) = try await urlSession.bytes(for: makeURLRequest(retryBody))
                if let retryHTTP = retryResponse as? HTTPURLResponse,
                   !(200 ..< 300).contains(retryHTTP.statusCode) {
                    let retryErrorBody = try await Self.collectBody(retryBytes)
                    throw LLMClientError.httpError(statusCode: retryHTTP.statusCode, body: retryErrorBody)
                }
                // 初回400を含むfallback全体をrequest時間として残しつつ、成功したSSEのheaders到着点を
                // consumerへ渡す。失敗responseをresponseStarted扱いするとモデル待ち時間を短く誤認する。
                continuation.yield(.responseStarted)
                try await consumeSSE(retryBytes, into: continuation)
                return
            }
            throw LLMClientError.httpError(statusCode: http.statusCode, body: errorBody)
        }

        continuation.yield(.responseStarted)
        try await consumeSSE(bytes, into: continuation)
    }

    /// SSE 本体を1行ずつ読み、LLMEvent へ翻訳して continuation に流す。
    private func consumeSSE(
        _ bytes: URLSession.AsyncBytes,
        into continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        var parser = SSELineParser()
        var completion = SSECompletionAccumulator()
        // usage-only チャンク(choices:[])で choices[0] を触らないため、蓄積は choices を
        // for で回す(空配列なら何もしない)。設計 §2 の MUST。

        // 【重要・なぜ bytes.lines を使わないか】URLSession.AsyncBytes の `.lines`(stdlib の
        // AsyncSequence.lines)は、この開発機の Swift 6.3(macOS 26)で **本当に空の行を
        // 1つも yield しない**ことを最小再現で確認した("a\n\nb" → ["a","b"]・間の空行が消える。
        // 空白1文字を挟むと消えない)。SSE はイベント境界を **空行** で表すので(SSELineParser が
        // line.isEmpty を境界に使う)、.lines 経由だと境界が永久に来ず、全 data チャンクが1つに
        // 連結されたまま [DONE] まで蓄積 → 複数 JSON 連結の不正文字列を一括 decode して
        // DecodingError で落ちる。本番 OpenAI(gpt-5.4-mini)のライブ検証でも同じクラッシュを再現した。
        // → stdlib の .lines を経由せず、生バイト列を自前で \n 分割する(空行を保持する)。
        // 末尾 \r は除去(SSE は \n / \r\n どちらもありうる)。SSELineParser 側は正しいので変更しない。
        var lineBuffer: [UInt8] = []
        var done = false

        // 1バイトずつ受けて \n(0x0A)で1行を確定し、パーサへ渡す。empty line(境界)も
        // ちゃんと "" として届くのが .lines との違い。
        for try await byte in bytes {
            guard byte != 0x0A else {
                // 行確定。CRLF の場合の末尾 \r を落としてからデコードする。
                if lineBuffer.last == 0x0D { lineBuffer.removeLast() }
                // SSEの不正UTF-8はストリーム全体を失敗させず置換文字としてパーサへ渡す。
                // swiftlint:disable:next optional_data_string_conversion
                let line = String(decoding: lineBuffer, as: UTF8.self)
                lineBuffer.removeAll(keepingCapacity: true)
                if let payload = parser.consume(line: line),
                   try completion.handle(payload: payload, continuation: continuation) {
                    // [DONE] を受けた。ループを抜けて completed を1回 yield する。
                    done = true
                    break
                }
                continue
            }
            lineBuffer.append(byte)
        }

        // 改行で締めずに切れた末尾行(最後のチャンクに \n が付かない実装揺れ)を拾う。
        if !done, !lineBuffer.isEmpty {
            if lineBuffer.last == 0x0D { lineBuffer.removeLast() }
            // 末尾断片も上と同じlossy UTF-8方針で回収する。
            // swiftlint:disable:next optional_data_string_conversion
            let line = String(decoding: lineBuffer, as: UTF8.self)
            if let payload = parser.consume(line: line) {
                done = try completion.handle(payload: payload, continuation: continuation)
            }
        }
        // ストリームが空行/[DONE] で締めずに切れたときの取りこぼし対策(保険・SSELineParser.flush)。
        if !done, let tail = parser.flush() {
            done = try completion.handle(payload: tail, continuation: continuation)
        }

        // HTTP EOFだけでは生成完了を証明できない。不完全tool引数を確定して実行せず、
        // 表示済みdeltaは残したまま既存のstream失敗経路へ渡す。finish_reasonのみ/DONEのみで
        // 終端する互換providerは許容し、DONEのみの場合の既存.other理由は保つ。
        guard done || completion.finishReason != nil else {
            throw LLMClientError.responseError("Chat stream ended before finish_reason or [DONE]")
        }
        continuation.yield(.completed(
            completion.finishReason ?? .other("no_finish_reason"),
            completion.toolCalls.finalize(),
            completion.usage
        ))
        continuation.finish()
    }

    // MARK: - リクエスト組み立て / ヘルパ

    private func makeURLRequest(_ body: ChatCompletionRequest) throws -> URLRequest {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // SSE を要求する(互換プロバイダによっては Accept を見る)。
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let encodedBody = try JSONEncoder().encode(body)
        request.httpBody = encodedBody
        let payloadMetrics = try Self.payloadMetrics(for: body, encodedBody: encodedBody)
        // 本文・tool名・schema自体は出さず、膨張の診断に必要な件数とbyte数だけを残す。
        Self.requestLogger.notice(
            "messages.count=\(payloadMetrics.messageCount, privacy: .public) system_prompt.utf8_bytes=\(payloadMetrics.systemPromptUTF8Bytes, privacy: .public) system_messages.json_bytes=\(payloadMetrics.systemMessagesJSONBytes, privacy: .public) conversation_messages.json_bytes=\(payloadMetrics.conversationMessagesJSONBytes, privacy: .public) messages.json_bytes=\(payloadMetrics.messagesJSONBytes, privacy: .public) tools.count=\(payloadMetrics.toolCount, privacy: .public) tools.json_bytes=\(payloadMetrics.toolsJSONBytes, privacy: .public) tool_schemas.json_bytes=\(payloadMetrics.toolSchemasJSONBytes, privacy: .public) tool_schemas.estimated_tokens=\(payloadMetrics.estimatedToolSchemaTokens, privacy: .public) request.json_bytes=\(payloadMetrics.requestJSONBytes, privacy: .public)"
        )
        return request
    }

    static func payloadMetrics(
        for body: ChatCompletionRequest,
        encodedBody: Data
    ) throws -> LLMRequestPayloadMetrics {
        let encoder = JSONEncoder()
        let systemMessages = body.messages.filter { $0.role == .system }
        let conversationMessages = body.messages.filter { $0.role != .system }
        let toolsJSONBytes = try body.tools.map { try encoder.encode($0).count } ?? 0
        let toolSchemasJSONBytes = try body.tools.map {
            try encoder.encode($0.map(\.function.parameters)).count
        } ?? 0
        return LLMRequestPayloadMetrics(
            messageCount: body.messages.count,
            systemPromptUTF8Bytes: systemMessages.compactMap(\.content)
                .reduce(0) { $0 + $1.utf8.count },
            systemMessagesJSONBytes: try systemMessages.isEmpty ? 0 : encoder.encode(systemMessages).count,
            conversationMessagesJSONBytes: try conversationMessages.isEmpty
                ? 0 : encoder.encode(conversationMessages).count,
            messagesJSONBytes: try encoder.encode(body.messages).count,
            toolCount: body.tools?.count ?? 0,
            toolsJSONBytes: toolsJSONBytes,
            toolSchemasJSONBytes: toolSchemasJSONBytes,
            // tokenizer非依存の診断値。JSONでは4 UTF-8 bytes/tokenを粗い目安として切り上げる。
            estimatedToolSchemaTokens: (toolSchemasJSONBytes + 3) / 4,
            requestJSONBytes: encodedBody.count
        )
    }

    /// エラー応答のボディ(通常 JSON の error オブジェクト)を文字列に集約する。
    /// SSE ではなく普通のレスポンスなので、バイトを全部集めて UTF-8 デコードするだけ。
    private static func collectBody(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        // HTTPエラー本文は診断用なので、不正バイトがあっても本文全体を捨てない。
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: data, as: UTF8.self)
    }
}

/// LLM アダプタ層のエラー。
public enum LLMClientError: Error, CustomStringConvertible {
    /// HTTP 非 2xx。ボディ(プロバイダの error JSON)を含めて検証・デバッグを助ける。
    case httpError(statusCode: Int, body: String)
    case responseError(String)

    public var description: String {
        switch self {
        case let .httpError(statusCode, body):
            return "LLM エンドポイントが HTTP \(statusCode) を返した: \(body)"
        case .responseError(let message):
            return "LLM response stream error: \(message)"
        }
    }
}

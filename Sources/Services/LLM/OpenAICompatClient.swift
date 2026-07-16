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

/// OpenAI 互換 SSE アダプタ。
///
/// actor でなく struct + Sendable: 保持する状態は不変(baseURL/apiKey/urlSession)だけで、
/// ストリーム実行中の可変状態(パーサ・アキュムレータ)は stream(_:) 内のローカルに閉じる。
/// 共有可変状態が無いので値型で並行安全にできる(actor の直列化オーバーヘッドも要らない)。
public struct OpenAICompatClient: LLMClient {
    private let baseURL: URL
    private let apiKey: String
    private let urlSession: URLSession

    /// - Parameters:
    ///   - baseURL: chat/completions のエンドポイント URL(例:
    ///     `https://api.openai.com/v1/chat/completions`)。パスまで含めた完全 URL を渡す
    ///     (プロバイダによって /v1 の有無が違うため、ここで組み立てず呼び出し側=BYOK 設定に委ねる)。
    ///   - apiKey: `Authorization: Bearer <key>` に載せる API キー。
    ///   - urlSession: 注入可能(テストで差し替え・既定は .shared)。
    public init(baseURL: URL, apiKey: String, urlSession: URLSession = .shared) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.urlSession = urlSession
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

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
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
                   !(200..<300).contains(retryHTTP.statusCode) {
                    let retryErrorBody = try await Self.collectBody(retryBytes)
                    throw LLMClientError.httpError(statusCode: retryHTTP.statusCode, body: retryErrorBody)
                }
                try await consumeSSE(retryBytes, into: continuation)
                return
            }
            throw LLMClientError.httpError(statusCode: http.statusCode, body: errorBody)
        }

        try await consumeSSE(bytes, into: continuation)
    }

    /// SSE 本体を1行ずつ読み、LLMEvent へ翻訳して continuation に流す。
    private func consumeSSE(
        _ bytes: URLSession.AsyncBytes,
        into continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async throws {
        var parser = SSELineParser()
        var accumulator = ToolCallAccumulator()
        var finishReason: FinishReason?
        var usage: Usage?
        // usage-only チャンク(choices:[])で choices[0] を触らないため、蓄積は choices を
        // for で回す(空配列なら何もしない)。設計 §2 の MUST。
        let decoder = JSONDecoder()

        // 1つの data ペイロード(1 SSE イベント)を処理する。[DONE] なら true を返す(終端合図)。
        func handle(payload: String) throws -> Bool {
            if payload == "[DONE]" {
                return true
            }
            let chunk = try decoder.decode(ChatCompletionChunk.self, from: Data(payload.utf8))
            // usage は finish_reason チャンクの後、choices 空の追加チャンクで届く(§2)。
            // choices を持つ通常チャンクにも usage:null が載るだけなので、非 nil のときだけ採る。
            if let chunkUsage = chunk.usage {
                usage = chunkUsage
            }
            for choice in chunk.choices {
                if let content = choice.delta.content, !content.isEmpty {
                    continuation.yield(.textDelta(content))
                }
                if let toolCalls = choice.delta.toolCalls {
                    accumulator.accumulate(toolCalls)
                }
                if let reason = choice.finishReason {
                    finishReason = reason
                }
            }
            return false
        }

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
                let line = String(decoding: lineBuffer, as: UTF8.self)
                lineBuffer.removeAll(keepingCapacity: true)
                if let payload = parser.consume(line: line), try handle(payload: payload) {
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
            let line = String(decoding: lineBuffer, as: UTF8.self)
            if let payload = parser.consume(line: line) {
                done = try handle(payload: payload)
            }
        }
        // ストリームが空行/[DONE] で締めずに切れたときの取りこぼし対策(保険・SSELineParser.flush)。
        if !done, let tail = parser.flush() {
            _ = try handle(payload: tail)
        }

        // finish_reason が最後まで来ないケース(中断・プロバイダ実装揺れ)は .other で可視化する
        // (握りつぶして .stop に寄せると「正常終了」に見えてしまうため)。
        continuation.yield(.completed(finishReason ?? .other("no_finish_reason"), accumulator.finalize(), usage))
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
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    /// エラー応答のボディ(通常 JSON の error オブジェクト)を文字列に集約する。
    /// SSE ではなく普通のレスポンスなので、バイトを全部集めて UTF-8 デコードするだけ。
    private static func collectBody(_ bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return String(decoding: data, as: UTF8.self)
    }
}

/// LLM アダプタ層のエラー。
public enum LLMClientError: Error, CustomStringConvertible {
    /// HTTP 非 2xx。ボディ(プロバイダの error JSON)を含めて検証・デバッグを助ける。
    case httpError(statusCode: Int, body: String)

    public var description: String {
        switch self {
        case let .httpError(statusCode, body):
            return "LLM エンドポイントが HTTP \(statusCode) を返した: \(body)"
        }
    }
}

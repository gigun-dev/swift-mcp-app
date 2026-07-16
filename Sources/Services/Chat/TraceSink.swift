// TraceSink 1 seam(設計 03 §3)。ChatViewModel の5注入点から ChatTraceEvent を受け取る
// 出力先の抽象。第一実装は OSLogTraceSink(このファイル)。将来 ChatStore 経由の永続化・
// デバッグ UI 表示に差し替える/追加するときもここだけを触ればよい(seam の価値・設計 03 §3)。
//
// ProxyTraceSink は作らない(設計 03 §3 決定): プロキシ段階ではサーバー側が全リクエストを見るため
// クライアント発トレースは不要。
import Foundation
import Kernel
import OSLog

/// トレースイベントの出力先。**fire-and-forget**——emit は同期に呼ばれ、
/// ChatViewModel の tool-use ループを絶対にブロックしてはならない(設計 03 §3)。
/// 重い処理(ファイル書き込み等)を行う実装は内部で非同期に逃がすこと。
public protocol TraceSink: Sendable {
    func emit(_ event: ChatTraceEvent)
}

/// OSLog(Unified Logging)へ1行 notice で出す第一実装。
///
/// subsystem/category は設計 03 §3 の指定どおり `dev.gigun.mcphost` / `chat-trace`
/// (既存の他ログ実装 —— KeychainTokenStorage・ChatHomeViewModel 等 —— と同じ subsystem に
/// 揃え、category だけを分けている。`log show --predicate 'category == "chat-trace"'` や
/// grep で1ターンの流れを追える、というユーザー要望に応える形)。
///
/// **1行に整形する理由**: OSLog の構造化ロギング(`Logger.log(level:, "\(x)")`)は
/// unified log 上ではメタデータ扱いになり、`log show` の素の出力では読みにくい。
/// ここでは人間が log show でそのまま読める・grep しやすいキー=値の1行文字列に自前で整形する
/// (例: `turn=<id> tool=<name> bytes=<n> err=<bool>`。指示の例をそのまま踏襲)。
public struct OSLogTraceSink: TraceSink {
    private let logger = Logger(subsystem: "dev.gigun.mcphost", category: "chat-trace")

    public init() {}

    public func emit(_ event: ChatTraceEvent) {
        switch event {
        case .turnStarted(let chatId, let turnId, let model):
            logger.notice("turnStarted chat=\(chatId, privacy: .public) turn=\(turnId, privacy: .public) model=\(model, privacy: .public)")

        case .llmCompleted(let turnId, let finishReason, let usage):
            // usage が届かないターン(ストリーム中断・02 §2 の但し書き)もあるので "-" で欠損を明示。
            let usageText = usage.map { "prompt=\($0.promptTokens) completion=\($0.completionTokens)" } ?? "-"
            logger.notice("llmCompleted turn=\(turnId, privacy: .public) reason=\(finishReason, privacy: .public) usage=\(usageText, privacy: .public)")

        case .toolCallStarted(let turnId, let callId, let name, _):
            // arguments 本体はログに出さない(ユーザーデータを unified log に平文で残さない判断・
            // 設計に明記は無いが「フル JSON をログに残す」はプライバシー上望ましくないためこう解釈)。
            logger.notice("toolCallStarted turn=\(turnId, privacy: .public) call=\(callId, privacy: .public) tool=\(name, privacy: .public)")

        case .toolCallFinished(let turnId, let callId, let isError, let resultBytes, let durationMs):
            logger.notice("toolCallFinished turn=\(turnId, privacy: .public) call=\(callId, privacy: .public) bytes=\(resultBytes) err=\(isError) ms=\(durationMs)")

        case .turnSettled(let turnId, let iterations, let cumulativeUsage):
            logger.notice("turnSettled turn=\(turnId, privacy: .public) iterations=\(iterations) cumPrompt=\(cumulativeUsage.promptTokens) cumCompletion=\(cumulativeUsage.completionTokens)")
        }
    }
}

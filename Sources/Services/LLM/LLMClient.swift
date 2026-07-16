// ベンダー中立の LLM ストリーミング補完プロトコル(設計 §2)。
//
// 「LLM エンドポイントを1箇所に抽象する」(CLAUDE.md ビジョン1・SaaS 展開時に
// BYOK → LLM プロキシへ差し替え可能に保つ)の実体がこのプロトコル。第一実装は
// OpenAICompatClient(OpenAI 互換 SSE)。将来 AnthropicClient を足すときも、この
// `stream(_:) -> AsyncThrowingStream<LLMEvent, Error>` の粒度に載せる(設計 §2 拡張点で
// 「Anthropic の content_block_delta / tool_use にも載る」ことを確認済み)。
//
// リクエスト/レスポンスのワイヤ型(ChatCompletionRequest / ToolCall / Usage / FinishReason)は
// Kernel/LLMProtocol(T1)にある。ここは「1ターンの補完をストリームで返す」契約だけを定義する。
import Foundation
import Kernel

/// 1ターン分の LLM 補完をストリーミングで要求する中立プロトコル。
///
/// Sendable 制約: ChatViewModel(Services/Chat・T3)が Task 越しに保持・呼び出すため、
/// アダプタ実装は並行安全であること(OpenAICompatClient は URLSession + 不変設定なので満たす)。
public protocol LLMClient: Sendable {
    /// リクエストを送り、delta イベントを非同期ストリームで返す。
    /// ストリームは textDelta を 0 個以上 yield した後、**必ず最後に completed を1回**
    /// yield して正常終了する(設計 §2: 終端イベントは completed に統合)。
    /// ネットワーク/デコード/HTTP エラーはストリームの throw で伝える。
    func stream(_ request: ChatCompletionRequest) -> AsyncThrowingStream<LLMEvent, Error>
}

/// ストリーム中に流れるイベント。設計 §2 の決定どおり2種類だけ。
public enum LLMEvent: Sendable {
    /// 本文の増分(assistant の吹き出しに逐次追記する)。空文字列は yield しない想定。
    case textDelta(String)

    /// ストリーム終端で1回だけ届く確定イベント。
    /// - FinishReason: stop / tool_calls など(モデルがなぜ止まったか)。
    /// - [ToolCall]: ToolCallAccumulator で確定済みの完成した tool_calls(無ければ空配列)。
    /// - Usage?: トークン使用量。**usage は `[DONE]` 直前の choices 空チャンクで届く**ため
    ///   終端に統合する(設計 §2)。中断時など届かないことがあるので optional。
    case completed(FinishReason, [ToolCall], Usage?)
}

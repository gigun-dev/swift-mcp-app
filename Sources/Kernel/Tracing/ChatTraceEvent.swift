// 観測(トレース)イベントの純データ型。設計 docs/design/03-tool-io-and-card-freshness.md §3。
//
// 「TraceSink 1 seam」の輪郭そのもの(設計 03 §3 のコードブロックを写経)。Kernel に置くのは
// ChatTraceEvent がプラットフォーム非依存の純データ・Codable だから(CLAUDE.md「Kernel は
// プラットフォーム非依存」)。TraceSink プロトコル自体(emit する側)は Services に置く
// (このイベントを OSLog や ChatStore へ渡す配線は Foundation より上のレイヤーの関心)。
//
// なぜ Kernel/LLMProtocol の Usage を再利用するか: 設計 03 §3 のコードブロックがそのまま
// `Usage?` を使っている(02 の Usage と同一・二重定義しない)。JSONValue も同様に
// Kernel/AppsProtocol の型を再利用する(素通し JSON 方針・冒頭 JSONValue.swift 参照)。
import Foundation

/// 1ターン内で起きる観測イベント。ChatViewModel の5注入点(送信ループ開始・LLM completed
/// 受領・ツール実行前後・ターン確定)に1対1で対応する(設計 03 §3)。
///
/// **fire-and-forget が前提**: このイベント自体は「何が起きたか」の記録に徹し、
/// 副作用(保存・ログ出力)は TraceSink 実装側の責務。ChatViewModel はこの enum を作って
/// emit するだけで、結果を待たない(ループを絶対にブロックしない・設計 03 §3 のコメントどおり)。
public enum ChatTraceEvent: Sendable, Codable, Equatable {
    /// send ループ開始(1ユーザー発話につき1回)。turnId は「1反復」ではなく
    /// 「1ユーザー発話に対する一連の反復」全体を指す ID(下記 turnSettled と対で使う想定)。
    case turnStarted(chatId: String, turnId: String, model: String)

    /// LLM ストリームの `.completed` 受領(反復1周ごとに1回)。
    /// finishReason は Kernel/LLMProtocol の `FinishReason.wireValue`(文字列)をそのまま積む
    /// ——ChatTraceEvent 自体は FinishReason 型に依存させず(Codable の enum with associated
    /// value は将来ケース追加に弱いので)、素の String で持つ判断(設計に明記無し・こう解釈)。
    case llmCompleted(turnId: String, finishReason: String, usage: Usage?)

    /// ツール実行1本の開始(execute 呼び出し直前)。callId は ToolCall.id(tool_call_id)。
    /// arguments は decodeArguments 済みの JSONValue(素通し・設計 02 §1 の JSONValue 方針)。
    case toolCallStarted(turnId: String, callId: String, name: String, arguments: JSONValue)

    /// ツール実行1本の終了。resultBytes は結果 JSON の UTF-8 バイト数(設計 03 §3
    // 「result 本体は ChatStore 側が持つ」— ここではサイズだけを持ち、本体は積まない
    // ことで「フル JSON 要約化は据え置き」の方針とも独立に、トレースは軽量に保つ)。
    // durationMs は execute の呼び出し前後で計測する実測値(Date().timeIntervalSince で算出。
    // 「計測できる範囲で」の指示どおり、ChatViewModel 側で Date を使って実測する — 0 固定にはしない)。
    case toolCallFinished(turnId: String, callId: String, isError: Bool, resultBytes: Int, durationMs: Int)

    /// 1ユーザー発話に対する一連の反復が確定(.stop 到達 or 最大反復打ち切り)。
    /// iterations は実際に回った反復数、cumulativeUsage はこのターンまでのセッション累計
    /// (ChatViewModel.cumulativeUsage をそのまま積む・設計 03 §3 のコードブロックどおり)。
    case turnSettled(turnId: String, iterations: Int, cumulativeUsage: Usage)
}

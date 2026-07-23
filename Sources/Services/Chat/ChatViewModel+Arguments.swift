// tool-call引数decodeのテスト口。会話状態機械本体の末尾へ実装詳細を足し続けず、
// 実処理の正典ToolCallRunnerへ薄く委譲する。
extension ChatViewModel {
    typealias ArgumentsDecodeResult = ToolCallRunner.ArgumentsDecodeResult

    static func decodeArguments(_ raw: String) -> ArgumentsDecodeResult {
        ToolCallRunner.decodeArguments(raw)
    }
}

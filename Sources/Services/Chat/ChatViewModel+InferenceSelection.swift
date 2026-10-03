// チャット中のモデル選択だけを本体から分離し、状態機械のファイル長と責務を増やさない。
extension ChatViewModel {
    /// 会話履歴を維持したまま、次のユーザー送信から使う推論条件を更新する。
    @discardableResult
    public func updateInference(model: String, reasoningEffort: String?) -> Bool {
        guard !isRunning else { return false }
        self.model = model
        self.reasoningEffort = reasoningEffort
        return true
    }
}

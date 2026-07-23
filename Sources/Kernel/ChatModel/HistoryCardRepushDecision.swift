// 履歴再訪カードの「保存済み toolResult を再 push すべきか」の純判定(2026-07-24・鮮度ギャップ修正)。
//
// UI ライフサイクル(SwiftUI の .task / onAppear)に絡む判定だが、判定式そのものは2つの bool の
// 組み合わせにすぎない。連続性・退行防止のため純関数へ切り出し、Kernel の swift-testing で固定する
// (rules/interaction.md「判定ロジックは Kernel の純関数に置き、テストで固定する」の精神に沿う)。
public enum HistoryCardRepushDecision {
    /// - Parameters:
    ///   - isHistoryRevisit: このカードが履歴詳細ビュー由来か。ライブ会話(ChatTurnView)では常に false。
    ///     ライブ初回配送(build 内 sendInitialPayload)と干渉させないためのゲート。
    ///   - startedNewBuild: 直近の buildIfNeeded がこの呼び出しで **新規 build を開始した**か。
    ///     true(初回)なら build 自身が toolResult を push するので再送不要(二重送信回避)。
    ///     false(既に build 済み = 履歴再訪での host 再利用)のときが、まさに再 push の対象。
    /// - Returns: 再 push すべきなら true。
    ///
    /// 「再表示1回につき1回」は呼び出し側の粒度で担保する: InlineCardView の .task(view の appear 単位で
    /// 1回起動・disappear で cancel・reappear で再起動)からこの判定を通す。body 再計算では .task は
    /// 再起動しないため、スクロール往復などの再表示1回ごとにちょうど1回だけ true になる。
    public static func shouldRepush(isHistoryRevisit: Bool, startedNewBuild: Bool) -> Bool {
        isHistoryRevisit && !startedNewBuild
    }
}

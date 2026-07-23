// ChatViewModel のカード snapshot 書き戻し。会話状態機械本体(ChatViewModel.swift)の file_length を
// 抑えるため、永続化まわりの実装をここへ分ける(ChatViewModel+Arguments と同じ分割方針)。
import Foundation
import Kernel

@MainActor
extension ChatViewModel {
    /// カードの WKWebView が確定した HTML を、その位置の CardEmbed へ書き戻す(履歴保存の鮮度更新)。
    /// expectedResourceUri がその位置の実カードと一致したときだけ書き込み、変わったら onTurnSettled で保存。
    public func setCardSnapshot(
        turnIndex: Int,
        cardIndex: Int,
        expectedResourceUri: String,
        html: String
    ) {
        let changed = ChatPersistenceAssembler.updateSnapshot(
            in: &turns,
            turnIndex: turnIndex,
            cardIndex: cardIndex,
            expectedResourceURI: expectedResourceUri,
            html: html
        )
        if changed { onTurnSettled?() }
    }
}

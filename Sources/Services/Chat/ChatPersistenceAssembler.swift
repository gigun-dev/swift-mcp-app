import Foundation
import Kernel

/// ChatViewModelの可変状態から永続化DTOを組み立て、遅延到着するカードsnapshotを安全に反映する。
///
/// UIから届くsnapshotはretry後の古いindexを指す可能性があるため、範囲だけでなくresource URIも照合する。
/// 同じHTMLは変更なしとして扱い、保存トリガの無駄な再発火を避ける。
enum ChatPersistenceAssembler {
    struct Input {
        let id: UUID
        let serverURL: URL
        let serverURLs: [URL]?
        let createdAt: Date
        let turns: [ChatTurn]
        let model: String
    }

    static func makeSession(_ input: Input) -> ChatSession {
        ChatSession(
            id: input.id,
            title: deriveTitle(from: input.turns),
            serverURL: input.serverURL,
            serverURLs: input.serverURLs,
            createdAt: input.createdAt,
            updatedAt: Date(),
            turns: input.turns,
            model: input.model
        )
    }

    static func updateSnapshot(
        in turns: inout [ChatTurn],
        turnIndex: Int,
        cardIndex: Int,
        expectedResourceURI: String,
        html: String
    ) -> Bool {
        guard turns.indices.contains(turnIndex),
              turns[turnIndex].cards.indices.contains(cardIndex),
              turns[turnIndex].cards[cardIndex].resourceUri == expectedResourceURI,
              turns[turnIndex].cards[cardIndex].snapshotHTML != html
        else { return false }

        turns[turnIndex].cards[cardIndex].snapshotHTML = html
        return true
    }

    private static func deriveTitle(from turns: [ChatTurn]) -> String {
        guard let firstUserText = turns.first(where: { $0.role == .user })?.text else {
            return "新規チャット"
        }
        let trimmed = firstUserText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "新規チャット" }
        return String(trimmed.prefix(40))
    }
}

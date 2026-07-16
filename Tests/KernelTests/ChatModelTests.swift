// Kernel/ChatModel の round-trip テスト(P3 T1)。§5 の永続化 DTO 兼用が
// 「保存して読み直しても同じ」ことを保証する。
import Foundation
import Testing
@testable import Kernel

private func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
    let data = try JSONEncoder().encode(value)
    return try JSONDecoder().decode(T.self, from: data)
}

@Test("ChatSession は空セッションでも round-trip する")
func chatSessionRoundTripEmpty() throws {
    let session = ChatSession(
        title: "新しいチャット",
        serverURL: URL(string: "https://caldav.gigun-dev.workers.dev/mcp")!,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    )
    #expect(try roundTrip(session) == session)
}

@Test("ChatSession はツールステップ・カード・usage を含むターンごと round-trip する")
func chatSessionRoundTripWithTurns() throws {
    let session = ChatSession(
        title: "今日の予定",
        serverURL: URL(string: "https://caldav.gigun-dev.workers.dev/mcp")!,
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        updatedAt: Date(timeIntervalSince1970: 1_700_000_100),
        turns: [
            ChatTurn(role: .user, text: "今日の予定を見せて"),
            ChatTurn(
                role: .assistant,
                text: "今日の予定はこちらです。",
                toolSteps: [
                    ToolCallStep(toolName: "list-events", state: .done, argumentsJSON: "{\"date\":\"2026-07-16\"}"),
                ],
                cards: [
                    CardEmbed(
                        toolName: "list-events",
                        resourceUri: "ui://agenda/list",
                        snapshotHTML: "<html><body>agenda</body></html>",
                        structuredContent: ["events": []]
                    ),
                ],
                usage: Usage(promptTokens: 200, completionTokens: 30, totalTokens: 230)
            ),
        ]
    )
    #expect(try roundTrip(session) == session)
}

@Test("ToolCallStep の state は全ケースで round-trip する")
func toolCallStepStateRoundTrip() throws {
    for state: ToolCallStep.State in [.pending, .running, .done, .failed] {
        let step = ToolCallStep(toolName: "refresh-todos", state: state)
        #expect(try roundTrip(step) == step)
    }
}

@Test("CardEmbed は snapshotHTML/structuredContent 省略でも round-trip する")
func cardEmbedRoundTripMinimal() throws {
    let card = CardEmbed(toolName: "list-todos", resourceUri: "ui://todos/list")
    #expect(try roundTrip(card) == card)
    #expect(card.snapshotHTML == nil)
    #expect(card.structuredContent == nil)
}

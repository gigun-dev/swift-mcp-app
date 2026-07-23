// 履歴カードの live 再接続同定(HistoricalCardResolver)と再 push 判定(HistoryCardRepushDecision)の
// テスト。特に「OAuth 再追加で serverID が変わっても serverURL 同一なら復元できる」ことと、
// 「曖昧(同一 URL 複数接続)・strict surface 落ち(app-only tool)では復元しない」ことを固定する
// (2026-07-24・履歴カードの正しさ slice の What)。
import Foundation
import Testing
@testable import Kernel

private let caldavURL = URL(string: "https://caldav.gigun-dev.workers.dev/mcp")!

/// list-todos を広告する健全な surface を作るヘルパ。serverID/url/slug を差し替えて各ケースを組む。
private func todosSurface(
    serverID: UUID,
    url: URL = caldavURL,
    slug: String = "caldav",
    originalTool: String = "list-todos"
) -> HistoricalCardSurface {
    let wire = ToolNamespacing.wireName(slug: slug, tool: originalTool)
    return HistoricalCardSurface(
        serverID: serverID,
        url: url,
        slug: slug,
        wireNames: [wire],
        originalToolNames: [originalTool],
        uiResourceURIs: [wire: "ui://\(slug)/todos.hash.html"]
    )
}

/// provenance 付き(serverID/serverURL/originalToolName あり)の保存済みカード。
private func todosCard(serverID: UUID, url: URL = caldavURL, slug: String = "caldav") -> CardEmbed {
    CardEmbed(
        toolName: ToolNamespacing.wireName(slug: slug, tool: "list-todos"),
        resourceUri: "ui://\(slug)/todos.OLD.html",  // 保存時 URI。現在の広告 URI へ差し替わる想定。
        serverID: serverID,
        serverURL: url,
        originalToolName: "list-todos"
    )
}

@Test("serverID 一致の厳密経路で解決する(通常ケース)")
func resolvesViaExactServerID() {
    let sid = UUID()
    let resolved = HistoricalCardResolver.resolve(
        card: todosCard(serverID: sid), surfaces: [todosSurface(serverID: sid)]
    )
    #expect(resolved?.wireName == "caldav__list-todos")
    #expect(resolved?.resourceURI == "ui://caldav/todos.hash.html")  // 現在広告の URI へ差し替わる。
    #expect(resolved?.surfaceIndex == 0)
}

@Test("旧 serverID でも serverURL 一致 + 広告 tool なら URL フォールバックで解決する(再追加バグ)")
func resolvesViaServerURLFallbackAfterReAdd() {
    // カードは旧 serverID を握るが、現在の接続は再追加で別 serverID。URL は同一。
    let oldSID = UUID()
    let newSID = UUID()
    let card = todosCard(serverID: oldSID)
    let resolved = HistoricalCardResolver.resolve(card: card, surfaces: [todosSurface(serverID: newSID)])
    #expect(resolved?.wireName == "caldav__list-todos")
    #expect(resolved?.surfaceIndex == 0)
}

@Test("serverURL がどの接続とも一致しないなら nil(別サーバーへ誤配送しない)")
func nilWhenURLMatchesNothing() {
    let card = todosCard(serverID: UUID(), url: caldavURL)
    let other = todosSurface(serverID: UUID(), url: URL(string: "https://other.example/mcp")!)
    #expect(HistoricalCardResolver.resolve(card: card, surfaces: [other]) == nil)
}

@Test("同一 serverURL の接続が複数あるなら nil(曖昧回避)")
func nilWhenAmbiguousSameURL() {
    // 再追加で別 serverID の同一 URL 接続が2本残っているケース。どちらへ復元すべきか断定できない。
    let card = todosCard(serverID: UUID())
    let surfaces = [todosSurface(serverID: UUID()), todosSurface(serverID: UUID())]
    #expect(HistoricalCardResolver.resolve(card: card, surfaces: surfaces) == nil)
}

@Test("URL 一致でも strict surface(素の tool)に無ければ nil(app-only tool の復活を防ぐ)")
func nilWhenAppOnlyToolNotOnSurface() {
    // wireName / uiResourceURIs は残るが originalToolNames から list-todos が消えた(app-only 化)状態。
    let sid = UUID()
    let wire = ToolNamespacing.wireName(slug: "caldav", tool: "list-todos")
    let appOnly = HistoricalCardSurface(
        serverID: sid,
        url: caldavURL,
        slug: "caldav",
        wireNames: [wire],
        originalToolNames: [],  // ← tools/list に素の tool が無い
        uiResourceURIs: [wire: "ui://caldav/todos.hash.html"]
    )
    // serverID も一致させて「厳密経路も strict surface で落ちる → URL フォールバックでも落ちる」を確認。
    #expect(HistoricalCardResolver.resolve(card: todosCard(serverID: sid), surfaces: [appOnly]) == nil)
}

@Test("旧履歴(provenance 無し)は wireName が一意広告のときだけ解決する")
func legacyResolvesWhenUniqueWireName() {
    let legacy = CardEmbed(toolName: "caldav__list-todos", resourceUri: "ui://caldav/todos.old.html")
    #expect(legacy.serverID == nil)
    let resolved = HistoricalCardResolver.resolve(card: legacy, surfaces: [todosSurface(serverID: UUID())])
    #expect(resolved?.wireName == "caldav__list-todos")

    // 同じ wireName を広告する接続が2本 → 曖昧回避で nil。
    let two = [todosSurface(serverID: UUID()), todosSurface(serverID: UUID())]
    #expect(HistoricalCardResolver.resolve(card: legacy, surfaces: two) == nil)
}

@Test("再 push 判定: 履歴再訪 かつ 既 build 済みのときだけ true")
func repushDecisionTruthTable() {
    // 履歴再訪 × 既 build(= 新規 build を開始していない)→ 再 push する。
    #expect(HistoryCardRepushDecision.shouldRepush(isHistoryRevisit: true, startedNewBuild: false))
    // 履歴再訪でも新規 build 時は build 自身が push する → 二重送信回避で false。
    #expect(!HistoryCardRepushDecision.shouldRepush(isHistoryRevisit: true, startedNewBuild: true))
    // ライブ会話(履歴でない)は常に false(初回配送と干渉しない)。
    #expect(!HistoryCardRepushDecision.shouldRepush(isHistoryRevisit: false, startedNewBuild: false))
    #expect(!HistoryCardRepushDecision.shouldRepush(isHistoryRevisit: false, startedNewBuild: true))
}

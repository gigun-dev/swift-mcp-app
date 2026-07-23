// queue 11 の観測整形(CardResolutionTelemetry)と、HistoricalCardResolver.resolveDetailed の
// **理由返却**を固定するテスト(What はテストに書く方針・CLAUDE.md「テスト = What」)。
// 実機のみ再現する「なぜ placeholder に落ちたか」を観測へ載せるのが queue 11 の主目的なので、
// 各失敗経路が期待どおりの CardResolutionReason を返すことをここで固める。
import Foundation
import Testing
@testable import Kernel

private let caldavURL = URL(string: "https://caldav.gigun-dev.workers.dev/mcp")!

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

private func todosCard(serverID: UUID, url: URL = caldavURL, slug: String = "caldav") -> CardEmbed {
    CardEmbed(
        toolName: ToolNamespacing.wireName(slug: slug, tool: "list-todos"),
        resourceUri: "ui://\(slug)/todos.OLD.html",
        serverID: serverID,
        serverURL: url,
        originalToolName: "list-todos"
    )
}

// MARK: - fields 整形

@Test("resolveFields は outcome/reason/tool/session を必ず載せ、provenance ありなら server 系も載せる")
func resolveFieldsCarriesCoreAndProvenance() {
    let sid = UUID()
    let fields = CardResolutionTelemetry.resolveFields(
        outcome: .placeholder,
        reason: .serverURLMismatch,
        card: todosCard(serverID: sid),
        session: "sess-123"
    )
    #expect(fields["outcome"] == "placeholder")
    #expect(fields["reason"] == "server-url-mismatch")
    #expect(fields["tool"] == "caldav__list-todos")
    #expect(fields["session"] == "sess-123")
    #expect(fields["expectedServerID"] == sid.uuidString)
    #expect(fields["serverURL"] == caldavURL.absoluteString)
}

@Test("resolveFields は旧履歴(server 系 nil)ではキー自体を出さない(未記録を区別できる)")
func resolveFieldsOmitsNilProvenance() {
    // provenance 無しの旧履歴カード(serverID/serverURL nil)。
    let legacy = CardEmbed(toolName: "caldav__list-todos", resourceUri: "ui://caldav/todos.old.html")
    let fields = CardResolutionTelemetry.resolveFields(
        outcome: .resolvedLive,
        reason: .legacyUnique,
        card: legacy,
        session: "sess-abc"
    )
    #expect(fields["outcome"] == "resolved-live")
    #expect(fields["reason"] == "legacy-unique")
    #expect(fields["expectedServerID"] == nil)  // キー自体が無い = provenance 未記録。
    #expect(fields["serverURL"] == nil)
}

// MARK: - resolveDetailed の理由

@Test("接続 0 本なら noReadyConnection")
func detailedNoReadyConnection() {
    let result = HistoricalCardResolver.resolveDetailed(card: todosCard(serverID: UUID()), surfaces: [])
    #expect(result.surface == nil)
    #expect(result.reason == .noReadyConnection)
}

@Test("serverID 一致の成功は serverIDMatch")
func detailedServerIDMatch() {
    let sid = UUID()
    let result = HistoricalCardResolver.resolveDetailed(
        card: todosCard(serverID: sid), surfaces: [todosSurface(serverID: sid)]
    )
    #expect(result.surface != nil)
    #expect(result.reason == .serverIDMatch)
}

@Test("再追加(serverID 変化)で URL 一致の成功は urlFallback")
func detailedURLFallback() {
    let result = HistoricalCardResolver.resolveDetailed(
        card: todosCard(serverID: UUID()), surfaces: [todosSurface(serverID: UUID())]
    )
    #expect(result.surface != nil)
    #expect(result.reason == .urlFallback)
}

@Test("URL がどの接続とも一致しないなら serverURLMismatch")
func detailedServerURLMismatch() {
    let card = todosCard(serverID: UUID(), url: caldavURL)
    let other = todosSurface(serverID: UUID(), url: URL(string: "https://other.example/mcp")!)
    let result = HistoricalCardResolver.resolveDetailed(card: card, surfaces: [other])
    #expect(result.surface == nil)
    #expect(result.reason == .serverURLMismatch)
}

@Test("同一 URL 複数なら ambiguousURL")
func detailedAmbiguousURL() {
    let card = todosCard(serverID: UUID())
    let surfaces = [todosSurface(serverID: UUID()), todosSurface(serverID: UUID())]
    let result = HistoricalCardResolver.resolveDetailed(card: card, surfaces: surfaces)
    #expect(result.surface == nil)
    #expect(result.reason == .ambiguousURL)
}

@Test("URL は一致するが strict surface(素の tool 消失)で弾かれたら appOnlyToolFiltered")
func detailedAppOnlyToolFiltered() {
    let sid = UUID()
    let wire = ToolNamespacing.wireName(slug: "caldav", tool: "list-todos")
    let appOnly = HistoricalCardSurface(
        serverID: sid,
        url: caldavURL,
        slug: "caldav",
        wireNames: [wire],
        originalToolNames: [],  // tools/list に素の tool が無い(app-only 化)。
        uiResourceURIs: [wire: "ui://caldav/todos.hash.html"]
    )
    let result = HistoricalCardResolver.resolveDetailed(card: todosCard(serverID: sid), surfaces: [appOnly])
    #expect(result.surface == nil)
    #expect(result.reason == .appOnlyToolFiltered)
}

@Test("provenance の serverURL 未記録なら missingServerURL")
func detailedMissingServerURL() {
    // serverID/originalToolName はあるが serverURL 欠落(部分記録の旧履歴)。厳密経路は URL 不一致で外れ、
    // フォールバックは serverURL nil で突き合わせ不能 → missingServerURL。
    let card = CardEmbed(
        toolName: "caldav__list-todos",
        resourceUri: "ui://caldav/todos.OLD.html",
        serverID: UUID(),
        serverURL: nil,
        originalToolName: "list-todos"
    )
    let result = HistoricalCardResolver.resolveDetailed(card: card, surfaces: [todosSurface(serverID: UUID())])
    #expect(result.surface == nil)
    #expect(result.reason == .missingServerURL)
}

@Test("旧履歴で wireName が一意広告なら legacyUnique、複数なら ambiguousWireName、無ければ noWireNameMatch")
func detailedLegacyReasons() {
    let legacy = CardEmbed(toolName: "caldav__list-todos", resourceUri: "ui://caldav/todos.old.html")
    #expect(legacy.serverID == nil)

    let unique = HistoricalCardResolver.resolveDetailed(card: legacy, surfaces: [todosSurface(serverID: UUID())])
    #expect(unique.surface != nil)
    #expect(unique.reason == .legacyUnique)

    let ambiguous = HistoricalCardResolver.resolveDetailed(
        card: legacy, surfaces: [todosSurface(serverID: UUID()), todosSurface(serverID: UUID())]
    )
    #expect(ambiguous.surface == nil)
    #expect(ambiguous.reason == .ambiguousWireName)

    // 別 slug の接続しか無い → wireName が一致せず noWireNameMatch。
    let noMatch = HistoricalCardResolver.resolveDetailed(
        card: legacy, surfaces: [todosSurface(serverID: UUID(), slug: "other")]
    )
    #expect(noMatch.surface == nil)
    #expect(noMatch.reason == .noWireNameMatch)
}

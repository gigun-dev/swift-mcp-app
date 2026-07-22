// ToolNamespacing(M2・ツール名の名前空間化)の純関数テスト。
// slug 生成の決定性・正規化・衝突回避・長さ制約、および前置↔逆引きの対称性を固定する。
import Testing
@testable import Kernel

@Suite struct ToolNamespacingTests {
    @Test("slug は小文字化して [a-z0-9-] に正規化する")
    func slugNormalizes() {
        #expect(ToolNamespacing.slug(for: "Caldav", existing: []) == "caldav")
        // 記号・空白はハイフンに寄せ、連続は畳み、先頭末尾は削る。
        #expect(ToolNamespacing.slug(for: "  My Server!! ", existing: []) == "my-server")
        #expect(ToolNamespacing.slug(for: "a__b", existing: []) == "a-b")
    }

    @Test("非 ASCII だけの名前は server にフォールバックする")
    func slugFallback() {
        #expect(ToolNamespacing.slug(for: "予定表", existing: []) == "server")
        #expect(ToolNamespacing.slug(for: "", existing: []) == "server")
    }

    @Test("既存 slug と衝突したら -2, -3 を付けて一意化する")
    func slugDedup() {
        #expect(ToolNamespacing.slug(for: "caldav", existing: ["caldav"]) == "caldav-2")
        #expect(ToolNamespacing.slug(for: "caldav", existing: ["caldav", "caldav-2"]) == "caldav-3")
    }

    @Test("maxLength を超える slug は切り詰められ、サフィックス込みでも収まる")
    func slugTruncates() {
        let long = String(repeating: "a", count: 100)
        let slug = ToolNamespacing.slug(for: long, existing: [], maxLength: 10)
        #expect(slug.count <= 10)
        #expect(slug == "aaaaaaaaaa")
        // 衝突時のサフィックスも maxLength を守る。
        let deduplicatedSlug = ToolNamespacing.slug(for: long, existing: [slug], maxLength: 10)
        #expect(deduplicatedSlug.count <= 10)
        #expect(deduplicatedSlug.hasSuffix("-2"))
    }

    @Test("prefixed と parse は対称(元ツール名に __ を含んでも境界は最初の __)")
    func prefixParseRoundTrip() {
        let prefixedName = ToolNamespacing.prefixed(slug: "caldav", tool: "list-todos")
        #expect(prefixedName == "caldav__list-todos")
        let parsed = ToolNamespacing.parse(prefixed: prefixedName)
        #expect(parsed?.slug == "caldav")
        #expect(parsed?.tool == "list-todos")

        // 元ツール名に __ が含まれても、slug 側は最初の __ までで確定する。
        let nestedPrefixedName = ToolNamespacing.prefixed(slug: "srv", tool: "weird__tool")
        let nestedParsed = ToolNamespacing.parse(prefixed: nestedPrefixedName)
        #expect(nestedParsed?.slug == "srv")
        #expect(nestedParsed?.tool == "weird__tool")
    }

    @Test("前置されていない/壊れた名前は parse で nil")
    func parseRejectsMalformed() {
        #expect(ToolNamespacing.parse(prefixed: "list-todos") == nil)   // 境界なし。
        #expect(ToolNamespacing.parse(prefixed: "__tool") == nil)       // slug 空。
        #expect(ToolNamespacing.parse(prefixed: "slug__") == nil)       // tool 空。
    }
}

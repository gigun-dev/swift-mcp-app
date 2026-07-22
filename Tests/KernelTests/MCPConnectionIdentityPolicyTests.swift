import Foundation
import Testing
@testable import Kernel

@Suite struct MCPConnectionIdentityPolicyTests {
    private let oldURL = URL(string: "https://old.example.com/mcp")!

    @Test("登録内容と期待 slug が同じ ready 接続は再利用する")
    func keepsMatchingConnection() {
        #expect(!MCPConnectionIdentityPolicy.requiresReconnect(
            connected: identity(name: "caldav", url: oldURL, slug: "caldav"),
            expected: identity(name: "caldav", url: oldURL, slug: "caldav")
        ))
    }

    @Test("名前編集後は旧 slug の ready 接続を再利用しない")
    func reconnectsAfterRename() {
        #expect(MCPConnectionIdentityPolicy.requiresReconnect(
            connected: identity(name: "caldav", url: oldURL, slug: "caldav"),
            expected: identity(name: "renamed", url: oldURL, slug: "renamed")
        ))
    }

    @Test("URL編集後は旧 endpoint の ready 接続を再利用しない")
    func reconnectsAfterURLChange() {
        #expect(MCPConnectionIdentityPolicy.requiresReconnect(
            connected: identity(name: "caldav", url: oldURL, slug: "caldav"),
            expected: identity(
                name: "caldav",
                url: URL(string: "https://new.example.com/mcp")!,
                slug: "caldav"
            )
        ))
    }

    @Test("登録順の変化で期待 slug が変わった接続を再採番する")
    func reconnectsWhenExpectedSlugChanges() {
        #expect(MCPConnectionIdentityPolicy.requiresReconnect(
            connected: identity(name: "same name", url: oldURL, slug: "same-name"),
            expected: identity(name: "same name", url: oldURL, slug: "same-name-2")
        ))
    }

    @Test("rename後に旧名と同名のserverを追加しても旧slugを残さない")
    func preventsDuplicateSlugAfterRenameAndAdd() {
        // 再現手順: A(caldav)をreadyにする → Aをrenamedへ変更 → Bをcaldav名で追加。
        // Aが旧slugを保持したままだとBもcaldavを割り当てられ、executor辞書で片方が上書きされる。
        var used = Set<String>()
        let expectedA = ToolNamespacing.slug(for: "renamed", existing: used)
        used.insert(expectedA)
        let expectedB = ToolNamespacing.slug(for: "caldav", existing: used)

        #expect(expectedA != expectedB)
        #expect(MCPConnectionIdentityPolicy.requiresReconnect(
            connected: identity(name: "caldav", url: oldURL, slug: "caldav"),
            expected: identity(name: "renamed", url: oldURL, slug: expectedA)
        ))
    }

    private func identity(name: String, url: URL, slug: String) -> MCPConnectionIdentity {
        MCPConnectionIdentity(name: name, url: url, slug: slug)
    }
}

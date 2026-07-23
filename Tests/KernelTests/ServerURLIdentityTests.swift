// ServerURLIdentity.canonicalKey(URL の同一性判定キー)の純関数テスト。
// add 冪等化(再追加での serverID 温存)が依存する「表層の揺れは同一・意味差は別」の契約を固定する。
import Foundation
import Testing
@testable import Kernel

@Suite struct ServerURLIdentityTests {
    @Test("末尾スラッシュの有無は同一キー")
    func trailingSlashCollapses() {
        let withSlash = ServerURLIdentity.canonicalKey(URL(string: "https://example.com/mcp/")!)
        let withoutSlash = ServerURLIdentity.canonicalKey(URL(string: "https://example.com/mcp")!)
        #expect(withSlash == withoutSlash)
    }

    @Test("ルート path の / と空は同一キー")
    func rootSlashCollapses() {
        let rootSlash = ServerURLIdentity.canonicalKey(URL(string: "https://example.com/")!)
        let noPath = ServerURLIdentity.canonicalKey(URL(string: "https://example.com")!)
        #expect(rootSlash == noPath)
    }

    @Test("host の大文字小文字差は同一キー")
    func hostCaseInsensitive() {
        let upperHost = ServerURLIdentity.canonicalKey(URL(string: "https://Example.COM/mcp")!)
        let lowerHost = ServerURLIdentity.canonicalKey(URL(string: "https://example.com/mcp")!)
        #expect(upperHost == lowerHost)
    }

    @Test("既定ポート明示と省略は同一キー")
    func defaultPortCollapses() {
        let httpsExplicit = ServerURLIdentity.canonicalKey(URL(string: "https://example.com:443/mcp")!)
        let httpsImplicit = ServerURLIdentity.canonicalKey(URL(string: "https://example.com/mcp")!)
        #expect(httpsExplicit == httpsImplicit)

        let httpExplicit = ServerURLIdentity.canonicalKey(URL(string: "http://example.com:80/mcp")!)
        let httpImplicit = ServerURLIdentity.canonicalKey(URL(string: "http://example.com/mcp")!)
        #expect(httpExplicit == httpImplicit)
    }

    @Test("非既定ポートは区別される")
    func nonDefaultPortDistinct() {
        let customPort = ServerURLIdentity.canonicalKey(URL(string: "https://example.com:8443/mcp")!)
        let defaultPort = ServerURLIdentity.canonicalKey(URL(string: "https://example.com/mcp")!)
        #expect(customPort != defaultPort)
    }

    @Test("fragment 差は同一キー")
    func fragmentIgnored() {
        let withFragment = ServerURLIdentity.canonicalKey(URL(string: "https://example.com/mcp#section")!)
        let withoutFragment = ServerURLIdentity.canonicalKey(URL(string: "https://example.com/mcp")!)
        #expect(withFragment == withoutFragment)
    }

    @Test("query 差は別キー(意味を持ちうるので保持)")
    func queryDistinct() {
        let tenantA = ServerURLIdentity.canonicalKey(URL(string: "https://example.com/mcp?tenant=a")!)
        let tenantB = ServerURLIdentity.canonicalKey(URL(string: "https://example.com/mcp?tenant=b")!)
        #expect(tenantA != tenantB)
        let noQuery = ServerURLIdentity.canonicalKey(URL(string: "https://example.com/mcp")!)
        #expect(tenantA != noQuery)
    }

    @Test("別 host は別キー")
    func differentHostDistinct() {
        let hostA = ServerURLIdentity.canonicalKey(URL(string: "https://a.example.com/mcp")!)
        let hostB = ServerURLIdentity.canonicalKey(URL(string: "https://b.example.com/mcp")!)
        #expect(hostA != hostB)
    }
}

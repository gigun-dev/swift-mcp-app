// MCPConnection の入口が UI の保存時検証に依存せず、保存済み/直接 API の不正 URL を
// transport 作成前に拒否することを固定する。ネットワークや OAuth delegate は使わない。
import Foundation
import Testing
@testable import Services

@Suite struct MCPConnectionEndpointPolicyTests {
    @Test("接続境界は既定で loopback HTTP も拒否する")
    func releaseEquivalentBoundaryRejectsLoopbackHTTP() throws {
        let endpoint = try #require(URL(string: "http://127.0.0.1:8787/mcp"))

        #expect(throws: (any Error).self) {
            try MCPConnection.validatedEndpoint(endpoint, allowInsecureLoopback: false)
        }
    }

    @Test("接続境界は明示許可された exact loopback HTTP だけ通す")
    func debugEquivalentBoundaryAcceptsExactLoopbackHTTP() throws {
        let endpoint = try #require(URL(string: "http://localhost:8787/mcp"))

        let validated = try MCPConnection.validatedEndpoint(
            endpoint,
            allowInsecureLoopback: true
        )

        #expect(validated == endpoint)
    }

    @Test("接続境界は開発許可中も LAN HTTP を拒否する")
    func boundaryRejectsLANHTTP() throws {
        let endpoint = try #require(URL(string: "http://192.168.1.10:8787/mcp"))

        #expect(throws: (any Error).self) {
            try MCPConnection.validatedEndpoint(endpoint, allowInsecureLoopback: true)
        }
    }
}

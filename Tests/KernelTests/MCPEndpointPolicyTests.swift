// MCPEndpointPolicy(サーバー登録フォームのエンドポイント URL 検証)の単体テスト。
// 目玉は「二重スキーム」— 旧実装(URL(string:) + scheme == "https" + host != nil)を
// すり抜けて実機で壊れたエントリを保存させたケースで、これが再発しないことを固定する
// (経緯は MCPEndpointPolicy.swift 冒頭)。
import Foundation
import Testing
@testable import Kernel

@Suite struct MCPEndpointPolicyTests {
    @Test("正常な https URL は通る")
    func acceptsHTTPS() throws {
        let url = try MCPEndpointPolicy.resolve(urlString: "https://caldav.gigun-dev.workers.dev/mcp").get()
        #expect(url.absoluteString == "https://caldav.gigun-dev.workers.dev/mcp")
    }

    @Test("連結された二重スキームは拒否(実機で踏んだ本命)")
    func rejectsDoubleScheme() {
        #expect(
            MCPEndpointPolicy.resolve(urlString: "https://http://tdr-concierge.gigun-dev.workers.dev/mcp")
                == .failure(.doubleScheme)
        )
    }

    @Test("同じスキームの二重貼りも拒否")
    func rejectsDoubleHTTPSScheme() {
        #expect(
            MCPEndpointPolicy.resolve(urlString: "https://https://example.com/mcp")
                == .failure(.doubleScheme)
        )
    }

    @Test("http のみは拒否(OAuth 前提・平文でトークンを流さない)")
    func rejectsPlainHTTP() {
        #expect(MCPEndpointPolicy.resolve(urlString: "http://example.com/mcp") == .failure(.notHTTPS))
    }

    @Test("開発許可を明示したときだけ exact loopback HTTP を通す", arguments: [
        "http://localhost:8787/mcp",
        "http://127.0.0.1:8787/mcp",
        "http://[::1]:8787/mcp"
    ])
    func acceptsExplicitlyAllowedLoopbackHTTP(_ rawURL: String) throws {
        #expect(
            try MCPEndpointPolicy.resolve(
                urlString: rawURL,
                allowInsecureLoopback: true
            ).get().absoluteString == rawURL
        )
    }

    @Test("Release 相当の既定 false は loopback HTTP も拒否", arguments: [
        "http://localhost:8787/mcp",
        "http://127.0.0.1:8787/mcp",
        "http://[::1]:8787/mcp"
    ])
    func rejectsLoopbackHTTPWithoutExplicitOptIn(_ rawURL: String) {
        #expect(MCPEndpointPolicy.resolve(urlString: rawURL) == .failure(.notHTTPS))
    }

    @Test("開発許可は LAN・公開・dotless host の HTTP へ広がらない", arguments: [
        "http://192.168.1.10:8787/mcp",
        "http://10.0.0.5:8787/mcp",
        "http://example.com/mcp",
        "http://mcpbox:8787/mcp"
    ])
    func rejectsNonLoopbackHTTPEvenWhenDevelopmentOptInIsEnabled(_ rawURL: String) {
        #expect(
            MCPEndpointPolicy.resolve(urlString: rawURL, allowInsecureLoopback: true)
                == .failure(.notHTTPS)
        )
    }

    @Test("スキーム無しは拒否")
    func rejectsMissingScheme() {
        #expect(MCPEndpointPolicy.resolve(urlString: "example.com/mcp") == .failure(.notHTTPS))
    }

    @Test("host 無し(プリフィルのまま)は拒否")
    func rejectsMissingHost() {
        #expect(MCPEndpointPolicy.resolve(urlString: "https://") == .failure(.invalidHost))
    }

    @Test("ドットの無い host は拒否(連結事故の残骸を弾く網)")
    func rejectsDotlessHost() {
        #expect(MCPEndpointPolicy.resolve(urlString: "https://http") == .failure(.invalidHost))
    }

    @Test("localhost はドット無しでも許容(将来のローカル開発サーバー)")
    func acceptsLocalhost() {
        #expect(MCPEndpointPolicy.resolve(urlString: "https://localhost:8787/mcp").isSuccess)
    }

    @Test("空文字は拒否")
    func rejectsEmpty() {
        #expect(MCPEndpointPolicy.resolve(urlString: "") == .failure(.empty))
    }

    @Test("空白だけも空文字と同じ扱い")
    func rejectsWhitespaceOnly() {
        #expect(MCPEndpointPolicy.resolve(urlString: "   \n ") == .failure(.empty))
    }

    @Test("前後の空白・改行はトリムして通す(ペースト由来のゴミで弾かない)")
    func trimsSurroundingWhitespace() throws {
        let url = try MCPEndpointPolicy.resolve(urlString: "  https://example.com/mcp\n").get()
        #expect(url.absoluteString == "https://example.com/mcp")
    }
}

/// テストの読みやすさ用の小道具(成功/失敗だけ見たいケース向け)。
private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}

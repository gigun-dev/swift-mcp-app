// OpenLinkPolicy(ui/open-link の URL 検証)の単体テスト(監査 2026-07-18 HIGH #2)。
// 純関数なので UIApplication/WKWebView 抜きで検証できる(OpenLinkPolicy.swift 冒頭コメント参照)。
import Testing
@testable import Kernel

@Suite struct OpenLinkPolicyTests {
    @Test("https は許可")
    func allowsHTTPS() {
        #expect(OpenLinkPolicy.resolve(urlString: "https://example.com/path?q=1") != nil)
    }

    @Test("http は許可")
    func allowsHTTP() {
        #expect(OpenLinkPolicy.resolve(urlString: "http://example.com") != nil)
    }

    @Test("javascript: は拒否(サンドボックス脱出経路)")
    func rejectsJavascriptScheme() {
        #expect(OpenLinkPolicy.resolve(urlString: "javascript:alert(1)") == nil)
    }

    @Test("file: は拒否(ローカルファイルアクセス経路)")
    func rejectsFileScheme() {
        #expect(OpenLinkPolicy.resolve(urlString: "file:///etc/passwd") == nil)
    }

    @Test("data: は拒否")
    func rejectsDataScheme() {
        #expect(OpenLinkPolicy.resolve(urlString: "data:text/html,<script>alert(1)</script>") == nil)
    }

    @Test("スキーム無しの壊れた文字列は拒否")
    func rejectsMalformedString() {
        #expect(OpenLinkPolicy.resolve(urlString: "not a url") == nil)
    }

    @Test("空文字は拒否")
    func rejectsEmptyString() {
        #expect(OpenLinkPolicy.resolve(urlString: "") == nil)
    }
}

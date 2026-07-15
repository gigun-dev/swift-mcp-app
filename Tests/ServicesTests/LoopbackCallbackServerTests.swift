// LoopbackCallbackServer の実挙動テスト。
//
// NWListener 版(旧実装)は Features 層(UIKit 依存)にあり自動テストできず、
// 実機で初めて EINVAL 失敗が発覚した(2026-07-15、docs/log.md)。その反省から、
// BSD ソケット版は「実際に bind して・実際に GET を投げて・URL が復元される」
// ところまでを swift test で回す。モックにしないのが目的そのもの。
import Foundation
import Testing

@testable import Services

@Suite struct LoopbackCallbackServerTests {
    @Test func 起動してコールバックを受け取れる() async throws {
        let server = LoopbackCallbackServer()
        let redirectURI = try server.start()

        // OS が選んだエフェメラルポートで 127.0.0.1 に bind できていること
        #expect(redirectURI.host == "127.0.0.1")
        #expect((redirectURI.port ?? 0) > 0)
        #expect(redirectURI.path == "/callback")

        // 認可サーバーのリダイレクトを URLSession で模倣(本物の HTTP GET)
        async let callback = server.waitForCallback()
        var callbackURL = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)!
        callbackURL.queryItems = [
            URLQueryItem(name: "code", value: "test-code"),
            URLQueryItem(name: "state", value: "test-state"),
        ]
        let (body, response) = try await URLSession.shared.data(from: callbackURL.url!)

        // ブラウザ側に 200 が返ること(ハング表示防止の応答)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: body, as: UTF8.self).contains("MCPHost"))

        // リダイレクト URL が code/state ごと正確に復元されること
        // (swift-sdk の extractCode がこの URL を authorizationRedirectURI と突き合わせる)
        let received = try await callback
        let comps = URLComponents(url: received, resolvingAgainstBaseURL: false)!
        #expect(comps.host == "127.0.0.1")
        #expect(comps.port == redirectURI.port)
        #expect(comps.path == "/callback")
        #expect(comps.queryItems?.first { $0.name == "code" }?.value == "test-code")
        #expect(comps.queryItems?.first { $0.name == "state" }?.value == "test-state")
    }

    @Test func キャンセルで待機が解除される() async throws {
        struct UserCancelled: Error {}
        let server = LoopbackCallbackServer()
        _ = try server.start()

        // async let はクロージャにキャプチャできない(コンパイルエラー)ため Task で持つ
        let callback = Task { try await server.waitForCallback() }
        // waitForCallback が continuation を登録するまでのわずかな間を置いてから cancel
        try await Task.sleep(for: .milliseconds(50))
        server.cancel(with: UserCancelled())

        await #expect(throws: UserCancelled.self) {
            _ = try await callback.value
        }
    }
}

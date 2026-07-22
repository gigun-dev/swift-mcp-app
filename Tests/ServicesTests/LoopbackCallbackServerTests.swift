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

    @Test func 事前接続が空で閉じられても本命のコールバックを受け取れる() async throws {
        // Safari/WebKit の投機的事前接続(preconnect)の再現: データを送らずに閉じる
        // TCP 接続が先行しても、サーバーが畳まれず本命の GET が通ること。
        // 初版はこれでサーバーごと落ちて「サーバに接続できなかった」になった
        // (シミュレータで実際に発生した障害の回帰テスト)。
        let server = LoopbackCallbackServer()
        let redirectURI = try server.start()
        async let callback = server.waitForCallback()

        // 事前接続を模倣: 生 TCP で繋いで何も送らず閉じる
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(redirectURI.port!)).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        close(fd)
        // サーバー側が空接続を処理する猶予
        try await Task.sleep(for: .milliseconds(100))

        // 本命の GET
        var callbackURL = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)!
        callbackURL.queryItems = [URLQueryItem(name: "code", value: "after-preconnect")]
        let (_, response) = try await URLSession.shared.data(from: callbackURL.url!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        let received = try await callback
        let comps = URLComponents(url: received, resolvingAgainstBaseURL: false)!
        #expect(comps.queryItems?.first { $0.name == "code" }?.value == "after-preconnect")
    }

    @Test func waitForCallback登録前に届いたコールバックも受け取れる() async throws {
        // caldav は承認済みクライアントの認可を対話なしで即時リダイレクトするため、
        // コールバックが waitForCallback() の登録より先に着弾しうる(シミュレータで
        // 「start() 前に waitForCallback() が呼ばれました」誤エラーとして実際に発生)。
        // 先着した結果が保持され、後から waitForCallback() しても受け取れることの回帰テスト。
        let server = LoopbackCallbackServer()
        let redirectURI = try server.start()

        // waitForCallback() を呼ぶ「前」にコールバックを完了させる
        var callbackURL = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)!
        callbackURL.queryItems = [URLQueryItem(name: "code", value: "early-bird")]
        let (_, response) = try await URLSession.shared.data(from: callbackURL.url!)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)

        // 後から待っても先着分が返る
        let received = try await server.waitForCallback()
        let comps = URLComponents(url: received, resolvingAgainstBaseURL: false)!
        #expect(comps.queryItems?.first { $0.name == "code" }?.value == "early-bird")
    }

    @Test func 複数ラウンドの認可コールバックを同じポートで受けられる() async throws {
        // swift-sdk は1接続の中で認可フローを複数回実行しうる(POST と SSE GET の
        // 2経路 401・トークン交換リトライ)。1回目のコールバックでサーバーを畳むと
        // 2回目が notStarted に化ける(シミュレータで実際に発生)。同じポートで
        // 2ラウンド受けられることの回帰テスト。
        let server = LoopbackCallbackServer()
        let redirectURI = try server.start()

        for round in 1 ... 2 {
            async let callback = server.waitForCallback()
            var callbackURL = URLComponents(url: redirectURI, resolvingAgainstBaseURL: false)!
            callbackURL.queryItems = [URLQueryItem(name: "code", value: "round-\(round)")]
            let (_, response) = try await URLSession.shared.data(from: callbackURL.url!)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            let received = try await callback
            let comps = URLComponents(url: received, resolvingAgainstBaseURL: false)!
            #expect(comps.queryItems?.first { $0.name == "code" }?.value == "round-\(round)")
        }
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

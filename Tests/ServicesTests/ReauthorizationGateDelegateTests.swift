// ReauthorizationGateDelegate の状態遷移を固定するテスト(design/08 §残課題)。
//
// What: 「確立前 = 内側 delegate へ委譲(ブラウザ提示許可)」「確立後 = ブラウザを開かず throw + 通知」
// を検証する。実ブラウザ(AuthenticationServices)は使わず、内側 delegate をフェイクに差し替えて
// プラットフォーム非依存に状態機械だけを固定する(Services で回す理由 = ラッパ本体の純ロジック)。
import Foundation
import MCP
import Testing
@testable import Services

private struct FakeInnerDelegate: OAuthAuthorizationDelegate, @unchecked Sendable {
    /// presentAuthorizationURL が委譲されたら返す固定のリダイレクト URL(= ブラウザ提示が起きた証拠)。
    let redirect: URL
    /// 呼ばれたことを外から観測するためのカウンタ(参照型で共有)。
    let callCount: Counter

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() { lock.lock(); value += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    }

    func presentAuthorizationURL(_ url: URL) async throws -> URL {
        callCount.increment()
        return redirect
    }
}

@Suite("ReauthorizationGateDelegate")
struct ReauthorizationGateDelegateTests {
    @Test("確立前は内側 delegate へ委譲し、ブラウザ提示(リダイレクト)を通す")
    func delegatesBeforeEstablishment() async throws {
        let counter = FakeInnerDelegate.Counter()
        let inner = FakeInnerDelegate(redirect: URL(string: "http://127.0.0.1/cb?code=x")!, callCount: counter)
        let gate = ReauthorizationGateDelegate(wrapping: inner)

        let result = try await gate.presentAuthorizationURL(URL(string: "https://as.example/authorize")!)

        #expect(result.absoluteString == "http://127.0.0.1/cb?code=x")
        #expect(counter.count == 1)             // 内側へ委譲された = ブラウザが出る初回認可経路。
        #expect(gate.didRequestReauthorization == false)
    }

    @Test("確立後はブラウザを開かず throw し、再認可コールバックを発火する")
    func throwsAndNotifiesAfterEstablishment() async throws {
        let counter = FakeInnerDelegate.Counter()
        let inner = FakeInnerDelegate(redirect: URL(string: "http://127.0.0.1/cb")!, callCount: counter)

        // コールバック発火の観測(transport 背後スレッド想定なので Sendable な参照型で受ける)。
        let notified = FakeInnerDelegate.Counter()
        let gate = ReauthorizationGateDelegate(wrapping: inner) { notified.increment() }

        gate.markEstablished()

        await #expect(throws: ReauthorizationGateDelegate.ReauthorizationRequired.self) {
            _ = try await gate.presentAuthorizationURL(URL(string: "https://as.example/authorize")!)
        }

        #expect(counter.count == 0)             // 内側へは委譲しない = ブラウザは開かない。
        #expect(notified.count == 1)            // 要再認可コールバックが1回発火。
        #expect(gate.didRequestReauthorization == true)
    }

    @Test("確立前の1回目はブラウザ、確立後の2回目は遮断(混在シーケンス)")
    func mixedSequence() async throws {
        let counter = FakeInnerDelegate.Counter()
        let inner = FakeInnerDelegate(redirect: URL(string: "http://127.0.0.1/cb?code=first")!, callCount: counter)
        let notified = FakeInnerDelegate.Counter()
        let gate = ReauthorizationGateDelegate(wrapping: inner) { notified.increment() }

        // 初回認可: 委譲されリダイレクトが返る。
        let first = try await gate.presentAuthorizationURL(URL(string: "https://as.example/authorize")!)
        #expect(first.absoluteString.contains("code=first"))
        #expect(counter.count == 1)
        #expect(notified.count == 0)

        // 接続確立 → 以後の再認可要求(refresh 失効)は遮断される。
        gate.markEstablished()
        await #expect(throws: ReauthorizationGateDelegate.ReauthorizationRequired.self) {
            _ = try await gate.presentAuthorizationURL(URL(string: "https://as.example/authorize")!)
        }
        #expect(counter.count == 1)             // 2回目は内側に届かない。
        #expect(notified.count == 1)
    }
}

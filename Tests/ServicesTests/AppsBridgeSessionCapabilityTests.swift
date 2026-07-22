// MCP Appsカードのfullscreen capability検出を検証する。
// 共通bridge fixtureを再利用しつつ、表示モード本体から独立した責務として分割する。
import Foundation
import Testing
import MCP

@testable import Kernel
@testable import Services

extension AppsBridgeSessionTests {
    // MARK: - カード capability(fullscreen 対応)の検出(UX #1・fable #1・apps.mdx:786)

    /// onCardCapabilities の受領値を記録する actor(initialize の非同期消化を跨いで観測する)。
    private actor CapabilityRecorder {
        private(set) var received: [Bool] = []
        func record(_ supportsFullscreen: Bool) { received.append(supportsFullscreen) }
        var count: Int { received.count }
    }

    @Test("appCapabilities に fullscreen があれば onCardCapabilities(true)")
    func cardCapabilitiesTrueWhenFullscreenDeclared() async throws {
        let transport = MockTransport()
        let recorder = CapabilityRecorder()
        let session = await makeReadySession(
            transport: transport,
            onCardCapabilities: { await recorder.record($0) },
            appCapabilitiesJSON: #"{"availableDisplayModes":["inline","fullscreen"]}"#)
        await waitUntil { await recorder.count >= 1 }
        #expect(await recorder.received == [true])
        await session.close()
    }

    @Test("appCapabilities に fullscreen が無ければ onCardCapabilities(false)")
    func cardCapabilitiesFalseWhenNotDeclared() async throws {
        let transport = MockTransport()
        let recorder = CapabilityRecorder()
        // 空の appCapabilities(availableDisplayModes 欠落)→ false に倒す(死にボタン排除)。
        let session = await makeReadySession(
            transport: transport,
            onCardCapabilities: { await recorder.record($0) })
        await waitUntil { await recorder.count >= 1 }
        #expect(await recorder.received == [false])
        await session.close()
    }
}

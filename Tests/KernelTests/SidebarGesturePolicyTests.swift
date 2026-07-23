import Testing
@testable import Kernel

@Suite("Sidebar gesture policy")
struct SidebarGesturePolicyTests {
    @Test("MCP Appの縦帯内だけopen開始を拒否する")
    func excludesMCPAppVerticalBands() {
        let bands = [100.0 ... 220.0, 300.0 ... 360.0]

        #expect(!SidebarGesturePolicy.canStartOpen(atY: 100, excludedVerticalBands: bands))
        #expect(!SidebarGesturePolicy.canStartOpen(atY: 180, excludedVerticalBands: bands))
        #expect(SidebarGesturePolicy.canStartOpen(atY: 250, excludedVerticalBands: bands))
    }

    @Test("横優位かつintent方向だけ指追従する")
    func filtersLiveTranslation() {
        #expect(SidebarGesturePolicy.liveTranslation(horizontal: 40, vertical: 5, intent: .open) == 40)
        #expect(SidebarGesturePolicy.liveTranslation(horizontal: -40, vertical: 5, intent: .open) == 0)
        #expect(SidebarGesturePolicy.liveTranslation(horizontal: -40, vertical: 5, intent: .close) == -40)
        #expect(SidebarGesturePolicy.liveTranslation(horizontal: 5, vertical: 40, intent: .close) == 0)
    }

    @Test("露出mainはtapと十分な左dragだけ閉じる")
    func resolvesExposedMainWithoutTapDragOverlap() {
        #expect(
            SidebarGesturePolicy.resolveExposedMain(
                horizontal: 2,
                vertical: 2,
                predictedHorizontal: 2,
                revealWidth: 330
            ) == .close
        )
        #expect(
            SidebarGesturePolicy.resolveExposedMain(
                horizontal: -90,
                vertical: 4,
                predictedHorizontal: -100,
                revealWidth: 330
            ) == .close
        )
        #expect(
            SidebarGesturePolicy.resolveExposedMain(
                horizontal: 30,
                vertical: 2,
                predictedHorizontal: 40,
                revealWidth: 330
            ) == .remainOpen
        )
        #expect(
            SidebarGesturePolicy.resolveExposedMain(
                horizontal: 3,
                vertical: 30,
                predictedHorizontal: 3,
                revealWidth: 330
            ) == .remainOpen
        )
    }
}

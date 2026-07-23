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

    @Test("横ロック済み前提でintent方向だけ指追従する")
    func filtersLiveTranslation() {
        // 縦横比較は lockAxis に移設したので、liveTranslation は intent 逆方向の丸めだけを担う。
        #expect(SidebarGesturePolicy.liveTranslation(horizontal: 40, intent: .open) == 40)
        #expect(SidebarGesturePolicy.liveTranslation(horizontal: -40, intent: .open) == 0)
        #expect(SidebarGesturePolicy.liveTranslation(horizontal: -40, intent: .close) == -40)
        #expect(SidebarGesturePolicy.liveTranslation(horizontal: 5, intent: .close) == 0)
    }

    @Test("初回translationで軸を一度だけ決める")
    func locksAxisOnce() {
        // 横優位・縦優位・拮抗時(等しいなら縦=scroll優先)の3ケース。
        #expect(SidebarGesturePolicy.lockAxis(horizontal: 40, vertical: 5) == .horizontal)
        #expect(SidebarGesturePolicy.lockAxis(horizontal: -40, vertical: 5) == .horizontal)
        #expect(SidebarGesturePolicy.lockAxis(horizontal: 5, vertical: 40) == .vertical)
        #expect(SidebarGesturePolicy.lockAxis(horizontal: 20, vertical: 20) == .vertical)
    }

    @Test("横ロック後は縦成分が増えても追従継続・縦ロックは呼ばれない")
    func axisLockKeepsTrackingRegardlessOfVertical() {
        // カクつきの根因だった「毎フレーム縦横判定」を排したことの回帰。横ロック済みなら
        // その後どれだけ縦成分が増えても liveTranslation は横の実値を返し続ける(0へ往復しない)。
        let axis = SidebarGesturePolicy.lockAxis(horizontal: 15, vertical: 3)
        #expect(axis == .horizontal)
        // 途中で縦成分が横成分を上回っても、ロック済み軸で liveTranslation を呼ぶ限り追従は途切れない。
        #expect(SidebarGesturePolicy.liveTranslation(horizontal: 30, intent: .open) == 30)
        #expect(SidebarGesturePolicy.liveTranslation(horizontal: 45, intent: .open) == 45)
        // 縦ロックした gesture は呼び出し側が liveTranslation を呼ばず 0 据え置き(= commit も不成立)。
        let vertical = SidebarGesturePolicy.lockAxis(horizontal: 3, vertical: 15)
        #expect(vertical == .vertical)
    }

    @Test("commitsは縦成分を見ず横の閾値だけで判定する")
    func commitsIgnoresVertical() {
        // 縦排除の責務は軸ロック(呼び出し側)へ移したので、commits は横だけを見る。
        // 22%閾値(330*0.22=72.6)を超える左dragは、縦成分がどうであれ commit する。
        #expect(SidebarGesturePolicy.commits(
            horizontal: -90, predictedHorizontal: -100, revealWidth: 330, intent: .close
        ))
        #expect(!SidebarGesturePolicy.commits(
            horizontal: -30, predictedHorizontal: -40, revealWidth: 330, intent: .close
        ))
        #expect(SidebarGesturePolicy.commits(
            horizontal: 90, predictedHorizontal: 100, revealWidth: 330, intent: .open
        ))
    }

    @Test("露出mainはtapと十分な左dragだけ閉じる")
    func resolvesExposedMainWithoutTapDragOverlap() {
        // slop 未満で軸未ロック(nil)は tap → close。
        #expect(
            SidebarGesturePolicy.resolveExposedMain(
                horizontal: 2,
                vertical: 2,
                predictedHorizontal: 2,
                revealWidth: 330,
                lockedAxis: nil
            ) == .close
        )
        // 横ロックかつ十分な左dragは close。
        #expect(
            SidebarGesturePolicy.resolveExposedMain(
                horizontal: -90,
                vertical: 4,
                predictedHorizontal: -100,
                revealWidth: 330,
                lockedAxis: .horizontal
            ) == .close
        )
        // 横ロックだが右dragで閾値未満は remainOpen。
        #expect(
            SidebarGesturePolicy.resolveExposedMain(
                horizontal: 30,
                vertical: 2,
                predictedHorizontal: 40,
                revealWidth: 330,
                lockedAxis: .horizontal
            ) == .remainOpen
        )
        // 縦ロック(縦scroll)は distance が slop を超えていても remainOpen(close へ誤変換しない)。
        #expect(
            SidebarGesturePolicy.resolveExposedMain(
                horizontal: 3,
                vertical: 30,
                predictedHorizontal: 3,
                revealWidth: 330,
                lockedAxis: .vertical
            ) == .remainOpen
        )
    }
}

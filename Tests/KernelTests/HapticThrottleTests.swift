// HapticThrottle のスロットル判定テスト(Date を注入するので実機/UIKit なしで検証できる)。
import Testing
@testable import Kernel
import Foundation

@Suite("HapticThrottle")
struct HapticThrottleTests {
    @Test("初回は必ず発火する")
    func firstCallFires() {
        var throttle = HapticThrottle(minInterval: 0.1)
        #expect(throttle.shouldFire(now: Date(timeIntervalSince1970: 0)) == true)
    }

    @Test("最小間隔未満の連続呼び出しは抑制される")
    func withinIntervalSuppressed() {
        var throttle = HapticThrottle(minInterval: 0.1)
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(throttle.shouldFire(now: t0) == true)
        #expect(throttle.shouldFire(now: t0.addingTimeInterval(0.05)) == false)
    }

    @Test("最小間隔ちょうど以上経てば再び発火する")
    func afterIntervalFiresAgain() {
        var throttle = HapticThrottle(minInterval: 0.1)
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(throttle.shouldFire(now: t0) == true)
        #expect(throttle.shouldFire(now: t0.addingTimeInterval(0.1)) == true)
    }

    @Test("抑制された呼び出しは lastFireDate を更新しない(基準点がずれない)")
    func suppressedCallDoesNotResetBaseline() {
        var throttle = HapticThrottle(minInterval: 0.1)
        let t0 = Date(timeIntervalSince1970: 0)
        #expect(throttle.shouldFire(now: t0) == true)
        // 0.05s 後は抑制される(基準は t0 のまま)。
        #expect(throttle.shouldFire(now: t0.addingTimeInterval(0.05)) == false)
        // 抑制呼び出しが基準を更新していなければ、t0+0.1 でちょうど再発火できるはず。
        #expect(throttle.shouldFire(now: t0.addingTimeInterval(0.1)) == true)
    }
}

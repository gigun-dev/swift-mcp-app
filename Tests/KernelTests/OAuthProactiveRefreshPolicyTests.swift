// OAuthProactiveRefreshPolicy(先回り refresh 窓・design/08 原則1)の境界テスト。
//
// What(このテストが固定する仕様): 送信直前に先回り refresh を始める「失効前スキュー窓」が
// design/08 の規則「5分(300s)。ただし TTL の10% が5分未満ならそちら = min(300, TTL*0.10)」に
// 従うこと。特に caldav 本番(TTL 3600s)で 300s が選ばれる境界(TTL 3000s = 50分)を挟んで検証する。
// swift-sdk・ネットワークには触れない純関数テスト(Xcode 無しの `swift test` で回る)。
import Foundation
import Testing
@testable import Kernel

@Suite struct OAuthProactiveRefreshPolicyTests {
    @Test("既定窓は 5分(300s)= Claude 公式コネクタの参照ベスプラ")
    func defaultWindowIsFiveMinutes() {
        #expect(OAuthProactiveRefreshPolicy.defaultWindowSeconds == 300)
    }

    @Test("caldav TTL 3600s では 300s(5分)が選ばれる(TTL*10%=360>300 で頭打ち)")
    func caldavTTLPicksFiveMinuteCap() {
        // caldav 本番 TTL。10% = 360s > 300s なので上限 300 に張り付く。
        #expect(OAuthProactiveRefreshPolicy.window(forTTLSeconds: 3600) == 300)
    }

    @Test("境界 TTL=3000s(50分)ちょうどで 300s(TTL*10% と 5分が一致)")
    func boundaryTTLEqualsFiveMinutes() {
        // TTL*10% = 300 = 5分。min(300, 300) = 300。境界の等値を固定する。
        #expect(OAuthProactiveRefreshPolicy.window(forTTLSeconds: 3000) == 300)
    }

    @Test("境界のすぐ下 TTL=2999s では TTL*10%(<300)が採られる")
    func justBelowBoundaryPicksTenPercent() {
        // TTL*10% = 299.9 < 300 なので動的側が採用される(「5分未満ならそちら」)。
        // 浮動小数の二進表現誤差(2999*0.1 = 299.90000000000003)を避け許容差で照合する。
        let window = OAuthProactiveRefreshPolicy.window(forTTLSeconds: 2999)
        #expect(abs(window - 299.9) < 0.001)
        #expect(window < OAuthProactiveRefreshPolicy.defaultWindowSeconds)
    }

    @Test("短命 TTL=60s では窓も TTL の10%(6s)へ縮む(発行直後の refresh 暴発を防ぐ)")
    func shortTTLShrinksWindow() {
        // 60s トークンに 300s 窓を当てると発行直後から常に窓内 = 毎回 refresh になる。
        // 10% = 6s まで縮めることで「末尾10%で先回り」の比を保つ。
        #expect(OAuthProactiveRefreshPolicy.window(forTTLSeconds: 60) == 6)
    }

    @Test("TTL 不明/無期限(0 以下)は既定 300s に倒す")
    func unknownTTLFallsBackToDefault() {
        // expires_in 無し(= 無期限 or 不明)は動的計算が意味を持たないので既定へ。
        #expect(OAuthProactiveRefreshPolicy.window(forTTLSeconds: 0) == 300)
        #expect(OAuthProactiveRefreshPolicy.window(forTTLSeconds: -1) == 300)
    }
}

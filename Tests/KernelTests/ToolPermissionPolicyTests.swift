// R4 許可ゲートの純関数判定(ToolPermissionPolicy.evaluate)の境界を固定する。
// What(テスト = 仕様): annotations(untrusted hint)× ユーザー決定 → 確認要否の全分岐。
// 性悪説の要点: 未申告は必ず確認・readOnly 申告だけが唯一の緩和・deny は annotations 無関係にブロック。
import Foundation
import Testing
@testable import Kernel

@Suite struct ToolPermissionPolicyTests {
    // openWorldHint 未申告(nil)の read-only。spec 既定は open-world=true なので緩和されない側。
    private let readOnly = ToolAnnotations(readOnlyHint: true)
    // 自動許可される唯一の形: read-only かつ open-world でないことを明示申告(caldav の全ツールがこれ)。
    private let readOnlyClosed = ToolAnnotations(readOnlyHint: true, openWorldHint: false)
    private let writeHint = ToolAnnotations(readOnlyHint: false, destructiveHint: true)
    // read-only だが open-world(外部システムに触れる web 系読み取り等)を明示申告したツール。
    private let readOnlyOpenWorld = ToolAnnotations(readOnlyHint: true, openWorldHint: true)

    @Test("deny はいかなる annotations でも deny(readOnly 申告でも・trust に関係なくブロック)")
    func denyAlwaysBlocks() {
        #expect(ToolPermissionPolicy.evaluate(annotations: readOnly, decision: .deny, trusted: true) == .deny)
        #expect(ToolPermissionPolicy.evaluate(annotations: nil, decision: .deny, trusted: true) == .deny)
        #expect(ToolPermissionPolicy.evaluate(annotations: writeHint, decision: .deny, trusted: true) == .deny)
        // trust は ask 緩和にしか効かない。untrusted でも deny は deny のまま。
        #expect(ToolPermissionPolicy.evaluate(annotations: readOnly, decision: .deny, trusted: false) == .deny)
    }

    @Test("allow は確認なしで proceed(trust に関係なく——ユーザーが常時許可済み)")
    func allowProceeds() {
        #expect(ToolPermissionPolicy.evaluate(annotations: nil, decision: .allow, trusted: true) == .proceed)
        #expect(ToolPermissionPolicy.evaluate(annotations: writeHint, decision: .allow, trusted: true) == .proceed)
        // trust は ask 緩和にしか効かない。untrusted でも明示 allow は proceed。
        #expect(ToolPermissionPolicy.evaluate(annotations: nil, decision: .allow, trusted: false) == .proceed)
    }

    @Test("ask + 未申告(nil)は確認必須(性悪説の既定)")
    func askUnannotatedConfirms() {
        #expect(ToolPermissionPolicy.evaluate(annotations: nil, decision: .ask, trusted: true) == .confirm)
    }

    @Test("ask + trusted + readOnly かつ openWorldHint==false だけが唯一の緩和で proceed")
    func askReadOnlyProceeds() {
        #expect(ToolPermissionPolicy.evaluate(annotations: readOnlyClosed, decision: .ask, trusted: true) == .proceed)
    }

    @Test("ask + untrusted は readOnly(closed)でも緩和しない(信頼が無ければ readOnly 申告を信じない)")
    func askUntrustedConfirms() {
        #expect(ToolPermissionPolicy.evaluate(annotations: readOnlyClosed, decision: .ask, trusted: false) == .confirm)
    }

    @Test("ask + readOnly だが openWorldHint 未申告(nil)は緩和しない(spec 既定 open-world=true とみなす)")
    func askReadOnlyOpenWorldUnsetConfirms() {
        #expect(ToolPermissionPolicy.evaluate(annotations: readOnly, decision: .ask, trusted: true) == .confirm)
    }

    @Test("ask + readOnly だが open-world 明示 true は緩和しない(外部システムに触れる読み取りは確認へ)")
    func askOpenWorldConfirms() {
        #expect(
            ToolPermissionPolicy.evaluate(annotations: readOnlyOpenWorld, decision: .ask, trusted: true) == .confirm
        )
    }

    @Test("ask + readOnlyHint==false / nil は確認必須(destructive 申告でも同じ confirm)")
    func askNonReadOnlyConfirms() {
        #expect(ToolPermissionPolicy.evaluate(annotations: writeHint, decision: .ask, trusted: true) == .confirm)
        // readOnlyHint を明示 false にしただけの annotations も緩和しない。
        #expect(
            ToolPermissionPolicy.evaluate(
                annotations: ToolAnnotations(readOnlyHint: false), decision: .ask, trusted: true
            ) == .confirm
        )
        // title だけ持つ(readOnlyHint 未申告)も確認必須。
        #expect(
            ToolPermissionPolicy.evaluate(
                annotations: ToolAnnotations(title: "X"), decision: .ask, trusted: true
            ) == .confirm
        )
    }

    @Test("autoAllowsWhenUnset は evaluate の .ask 緩和条件と一致する(設定表示 = runtime 挙動)")
    func autoAllowsMatchesRuntime() {
        // trusted + readOnly + openWorldHint==false 明示 → 自動許可 true(唯一の緩和形)。
        #expect(ToolPermissionPolicy.autoAllowsWhenUnset(annotations: readOnlyClosed, trusted: true) == true)
        // untrusted → 緩和しない。
        #expect(ToolPermissionPolicy.autoAllowsWhenUnset(annotations: readOnlyClosed, trusted: false) == false)
        // openWorldHint 未申告(nil)→ spec 既定 open-world とみなして緩和しない。
        #expect(ToolPermissionPolicy.autoAllowsWhenUnset(annotations: readOnly, trusted: true) == false)
        // open-world 明示 true → 緩和しない。
        #expect(ToolPermissionPolicy.autoAllowsWhenUnset(annotations: readOnlyOpenWorld, trusted: true) == false)
        // readOnly 未申告 / false → 緩和しない。
        #expect(ToolPermissionPolicy.autoAllowsWhenUnset(annotations: nil, trusted: true) == false)
        #expect(ToolPermissionPolicy.autoAllowsWhenUnset(annotations: writeHint, trusted: true) == false)
    }

    @Test("isLikelyDestructive: 未申告は性悪説で破壊的・readOnly は非破壊・明示 false は非破壊")
    func destructiveHeuristic() {
        #expect(ToolAnnotations().isLikelyDestructive == true)          // 未申告 → 破壊的とみなす
        #expect(readOnly.isLikelyDestructive == false)                   // readOnly は非破壊
        #expect(ToolAnnotations(destructiveHint: false).isLikelyDestructive == false)
        #expect(ToolAnnotations(destructiveHint: true).isLikelyDestructive == true)
    }

    @Test("ToolPermissionDecision は UserDefaults 保存のため rawValue で round-trip する")
    func decisionRawValueRoundTrip() {
        for decision in ToolPermissionDecision.allCases {
            #expect(ToolPermissionDecision(rawValue: decision.rawValue) == decision)
        }
    }
}

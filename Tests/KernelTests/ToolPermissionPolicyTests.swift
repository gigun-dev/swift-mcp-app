// R4 許可ゲートの純関数判定(ToolPermissionPolicy.evaluate)の境界を固定する。
// What(テスト = 仕様): annotations(untrusted hint)× ユーザー決定 → 確認要否の全分岐。
// 性悪説の要点: 未申告は必ず確認・readOnly 申告だけが唯一の緩和・deny は annotations 無関係にブロック。
import Foundation
import Testing
@testable import Kernel

@Suite struct ToolPermissionPolicyTests {
    private let readOnly = ToolAnnotations(readOnlyHint: true)
    private let writeHint = ToolAnnotations(readOnlyHint: false, destructiveHint: true)

    @Test("deny はいかなる annotations でも deny(readOnly 申告でもブロック)")
    func denyAlwaysBlocks() {
        #expect(ToolPermissionPolicy.evaluate(annotations: readOnly, decision: .deny) == .deny)
        #expect(ToolPermissionPolicy.evaluate(annotations: nil, decision: .deny) == .deny)
        #expect(ToolPermissionPolicy.evaluate(annotations: writeHint, decision: .deny) == .deny)
    }

    @Test("allow は確認なしで proceed(ユーザーが常時許可済み)")
    func allowProceeds() {
        #expect(ToolPermissionPolicy.evaluate(annotations: nil, decision: .allow) == .proceed)
        #expect(ToolPermissionPolicy.evaluate(annotations: writeHint, decision: .allow) == .proceed)
    }

    @Test("ask + 未申告(nil)は確認必須(性悪説の既定)")
    func askUnannotatedConfirms() {
        #expect(ToolPermissionPolicy.evaluate(annotations: nil, decision: .ask) == .confirm)
    }

    @Test("ask + readOnlyHint==true だけが唯一の緩和で proceed")
    func askReadOnlyProceeds() {
        #expect(ToolPermissionPolicy.evaluate(annotations: readOnly, decision: .ask) == .proceed)
    }

    @Test("ask + readOnlyHint==false / nil は確認必須(destructive 申告でも同じ confirm)")
    func askNonReadOnlyConfirms() {
        #expect(ToolPermissionPolicy.evaluate(annotations: writeHint, decision: .ask) == .confirm)
        // readOnlyHint を明示 false にしただけの annotations も緩和しない。
        #expect(
            ToolPermissionPolicy.evaluate(
                annotations: ToolAnnotations(readOnlyHint: false), decision: .ask
            ) == .confirm
        )
        // title だけ持つ(readOnlyHint 未申告)も確認必須。
        #expect(
            ToolPermissionPolicy.evaluate(
                annotations: ToolAnnotations(title: "X"), decision: .ask
            ) == .confirm
        )
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

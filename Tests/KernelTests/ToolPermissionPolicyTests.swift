// R4 許可ゲートの純関数判定(ToolPermissionPolicy)の境界を固定する。
// What(テスト = 仕様):
//  - evaluate(decision:) は素の写像(allow→proceed / ask→confirm / deny→deny)。annotations は見ない。
//  - 緩和(readOnly 自動許可)は defaultDecision(未保存の既定)へ隔離(2026-07-24 refactor・設計の穴修正)。
// 性悪説の要点: 未保存の既定は原則 ask・readOnly closed trusted だけが .allow・明示決定は hint に優先。
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

    // MARK: evaluate は決定を素直に写すだけ(annotations/trusted はもう見ない)

    @Test("evaluate: deny→deny / allow→proceed / ask→confirm の素の写像")
    func evaluateMapsDecisionOnly() {
        #expect(ToolPermissionPolicy.evaluate(decision: .deny) == .deny)
        #expect(ToolPermissionPolicy.evaluate(decision: .allow) == .proceed)
        #expect(ToolPermissionPolicy.evaluate(decision: .ask) == .confirm)
    }

    @Test("evaluate: 明示 .ask は annotations に関係なく必ず confirm(設計の穴回帰・明示決定は hint に優先)")
    func evaluateExplicitAskAlwaysConfirms() {
        // readOnly closed(自動許可されうる annotations)でも、ユーザーが明示 .ask を選べば確認する。
        // 以前は evaluate が readOnly を緩和して確認をスキップし、明示選択を握りつぶしていた(修正済み)。
        #expect(ToolPermissionPolicy.evaluate(decision: .ask) == .confirm)
    }

    // MARK: defaultDecision — 未保存ツールの既定(緩和が効く唯一の層)

    @Test("defaultDecision: trusted + readOnly closed だけ .allow(自動許可)、それ以外は .ask")
    func defaultDecisionBoundaries() {
        // 唯一の自動許可形: trusted + readOnly + openWorldHint==false 明示。
        #expect(ToolPermissionPolicy.defaultDecision(annotations: readOnlyClosed, trusted: true) == .allow)
        // openWorldHint==true → 外部システムに触れる読み取りは自動許可しない。
        #expect(ToolPermissionPolicy.defaultDecision(annotations: readOnlyOpenWorld, trusted: true) == .ask)
        // openWorldHint 未申告(nil)→ spec 既定 open-world=true とみなして自動許可しない。
        #expect(ToolPermissionPolicy.defaultDecision(annotations: readOnly, trusted: true) == .ask)
        // untrusted → readOnly closed でも自動許可しない(信頼が無ければ hint を信じない)。
        #expect(ToolPermissionPolicy.defaultDecision(annotations: readOnlyClosed, trusted: false) == .ask)
        // 非 readOnly / 未申告 → 自動許可しない。
        #expect(ToolPermissionPolicy.defaultDecision(annotations: writeHint, trusted: true) == .ask)
        #expect(ToolPermissionPolicy.defaultDecision(annotations: nil, trusted: true) == .ask)
    }

    @Test("autoAllowsWhenUnset は defaultDecision の緩和条件と一致する(設定表示 = runtime 挙動)")
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

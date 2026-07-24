// XCUIAutomation の native UI 回帰層(Fable queue 1 = B0 の土台実証)。
//
// 【なぜ XCUITest か / 何を守るか】ロジック層(Kernel/Services)は swift-testing で厚く固めているが、
// SwiftUI の View 構築・ナビゲーション・起動経路は SPM テストの外側にあり、これまで simulator-operator の
// 手動探索だけで見ていた(= 恒久回帰にならない)。このターゲットは「安定した native flow を
// XCUIAutomation へ昇格する」(docs/next-directions.md 完了条件)ための最小の土台。まずは通常起動が
// 破綻しないことだけを1本で押さえ、スキーム/署名/destination/identifier 対応が実際に回ることを実証する。
//
// 【なぜ pre-push 必須にしないか】UITest はシミュレータ起動を伴い遅く・環境要因で flaky になりやすい。
// pre-push(make verify)には入れず、`make uitest SIMULATOR_UDID=<udid>` の project E2E 扱いにする
// (Makefile の uitest ターゲット注記参照)。
import XCTest

final class SmokeUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        // 最初の失敗で即停止(後続アサートの二次被害ログを避け、原因を1点に絞る)。
        continueAfterFailure = false
    }

    /// 通常起動(スパイク env 無し = default 経路 = ChatHomeView)で、ルート画面のアンカーが現れることを確認する。
    ///
    /// アンカーは ChatHomeView ツールバーの ☰ ボタン(accessibilityIdentifier "home.root")。接続状態
    /// (.ready/.failed/未接続)に関わらず常在するので「ルート画面が LLM キー無しでも起動できたか」を
    /// 最小コストで掴める。**LLM キーは渡さない** —— キー未設定でも主画面が出ることの確認を兼ねる。
    /// onAppear の無言接続はネットワークを触るが、このアサートは接続結果に依存しない(ボタンは即在る)。
    func testLaunchShowsChatHomeRoot() {
        let app = XCUIApplication()
        app.launch()
        let root = app.buttons["home.root"]
        // 起動 + 初回レイアウトの猶予(CI 無し・実機シミュレータのコールドスタートを見込んで広めの 20s)。
        XCTAssertTrue(
            root.waitForExistence(timeout: 20),
            "通常起動で ChatHome のルート(☰ ツールバーボタン・home.root)が現れるはず"
        )
    }
}

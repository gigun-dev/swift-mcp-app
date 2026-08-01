// 入力欄まわりのキーボード挙動の回帰層。
//
// 【何を守るか】「メッセージ領域をタップしたらキーボードが閉じる」こと。
// これは ChatBodyView が simultaneousGesture で実現している挙動で、
// 2026-08-01 にジェスチャの適用範囲を VStack 全体からメッセージ領域だけへ狭めた際に、
// 本来の意図(タップ外しで閉じる)まで壊していないことを担保するために置いている。
//
// 【なぜ「長押しでキーボードが閉じない」側のテストが無いのか(重要)】
// 同じ修正が直した本題は「入力欄でカーソルを長押し(ペースト操作)するとキーボードが閉じる」
// 不具合だが、**その症状は XCUITest では再現できない**。press(forDuration:) で長押しを送っても、
// テキストを入れた状態で長押ししても、修正前のビルドで green のままだった
// (合成タッチイベントでは iOS のテキスト選択インタラクションが実機と同じには動かないためと思われる)。
// 一度は「長押ししてもキーボードが残る」テストを書いたが、修正前後で同じ結果になり
// 回帰テストとして機能しないと分かったので削除した。green のまま残すと「守られている」と
// 誤解させるぶん有害と判断した(この判断の記録としてこのコメントを残す)。
// 実際の確定は「修正前のビルドを実機に入れて再現 → 修正版で解消」を人手で確認して行った。
//
// 【flaky 対策】キーボードの出現はアニメーションを伴うので waitForExistence で待つ。
// Simulator が「ハードウェアキーボード接続」(⌘K でトグル)だとソフトキーボードが出ないため、
// その環境では XCTSkip する —— これを入れておかないと、環境設定の問題を
// アプリの不具合と誤診する(実際にこのセッションで踏んだ)。
import XCTest

final class ComposerKeyboardUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// メッセージ領域のタップでキーボードが閉じること。
    func testTapOnMessageAreaDismissesKeyboard() throws {
        let app = XCUIApplication()
        app.launch()

        // ルート画面が出るまで待つ(SmokeUITests と同じアンカー・コールドスタートを見込んで広め)。
        XCTAssertTrue(
            app.buttons["home.root"].waitForExistence(timeout: 20),
            "ChatHome のルート(home.root)が現れるはず"
        )

        // SwiftUI の TextField(axis: .vertical)は環境により textField / textView のどちらにも
        // 現れうるので両方を見る。identifier は ChatComposerView 側で付けている。
        let field = firstComposerField(in: app)
        XCTAssertTrue(field.waitForExistence(timeout: 10), "入力欄(chat.composer.input)が在るはず")
        field.tap()

        guard app.keyboards.element.waitForExistence(timeout: 5) else {
            throw XCTSkip("ソフトキーボードが出ない環境のためスキップ(Simulator の ⌘K / Connect Hardware Keyboard を確認)")
        }

        // メッセージ領域(画面上寄りの中央)をタップする。会話が空でも余白は contentShape で
        // 拾える前提の実装なので、座標指定で十分。
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()

        XCTAssertTrue(
            waitForKeyboardToDisappear(app, timeout: 3),
            "メッセージ領域のタップではキーボードが閉じるはず"
        )
    }

    // MARK: - ヘルパ

    /// textFields / textViews のどちらに出ても拾えるようにする。
    private func firstComposerField(in app: XCUIApplication) -> XCUIElement {
        let byField = app.textFields["chat.composer.input"]
        return byField.exists ? byField : app.textViews["chat.composer.input"]
    }

    /// キーボードが消えるまで待つ(消えたら true)。
    private func waitForKeyboardToDisappear(_ app: XCUIApplication, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !app.keyboards.element.exists { return true }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return !app.keyboards.element.exists
    }
}

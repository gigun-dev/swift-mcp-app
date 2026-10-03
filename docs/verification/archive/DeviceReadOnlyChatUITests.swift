import XCTest

// 実機の保存済み設定を使い、資格情報やKeychainを初期化せず通常composerを通す。
// 回答のデータ整合は同turnのOTel/サーバー結果で裏取る。画面上の完了だけで保証しない。
final class DeviceReadOnlyChatUITests: XCTestCase {
    func testCalendarAndTodosThroughPreservedConnection() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["home.root"].waitForExistence(timeout: 20))
        capture(app, name: "preserved-settings-start")
        for (index, prompt) in [
            "接続検証。CalDAVの今日の予定をAsia/Tokyoで取得してください。作成・変更・削除はしないでください。",
            "接続検証。CalDAVの未完了todoを取得してください。作成・変更・削除はしないでください。"
        ].enumerated() {
            let textField = app.textFields["chat.composer.input"]
            let field = textField.exists ? textField : app.textViews["chat.composer.input"]
            XCTAssertTrue(field.waitForExistence(timeout: 20))
            XCTAssertTrue(waitUntilEnabled(field, timeout: 120))
            field.tap()
            field.typeText(prompt)
            // unlabelled SF-symbol send buttonを、実AX frameとcomposer範囲で一意に求める。
            // toolbarやmodel-selectionを押す座標推測はしない。候補が一意でなければ停止する。
            let composer = field.frame
            let candidates = app.buttons.allElementsBoundByIndex.filter {
                let frame = $0.frame
                return $0.isEnabled && frame.width >= 25 && frame.width <= 45
                    && frame.height >= 25 && frame.height <= 45 && frame.midX > composer.midX
                    && frame.minY >= composer.minY && frame.minY <= composer.maxY + 100
            }
            XCTAssertEqual(candidates.count, 1, "composer内の送信ボタンが一意に見つかる必要がある")
            guard let send = candidates.first else { return }
            send.tap()
            XCTAssertTrue(app.staticTexts[prompt].waitForExistence(timeout: 10), "送信した質問が履歴に現れる")
            XCTAssertTrue(waitUntilEnabled(field, timeout: 120), "応答がsettleして次の入力が可能になる")
            // キーボードを閉じて回答/カードを証拠に残す。表示内容の成功判定は親のOTel照合が担当。
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)).tap()
            capture(app, name: "read-only-question-\(index + 1)")
            print("DEVICE_READ_ONLY_QUESTION completed=\(index + 1) prompt=\(prompt)")
        }
        // アプリを再起動し、認可ブラウザなしにルートへ戻る証拠を採取する。
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["home.root"].waitForExistence(timeout: 20))
        capture(app, name: "relaunch-preserved-settings")
    }

    private func waitUntilEnabled(_ field: XCUIElement, timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate { _, _ in field.exists && field.isEnabled }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout)
            == .completed
    }

    private func capture(_ app: XCUIApplication, name: String) {
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = name
        image.lifetime = .keepAlways
        add(image)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name)-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }
}

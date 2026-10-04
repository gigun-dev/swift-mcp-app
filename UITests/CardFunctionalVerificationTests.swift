import XCTest

/// Opt-in destructive smoke test; only the synthetic 0016 list is edited.
/// Seed/authentication/viewport prerequisites are in the CalDAV mobile review document.
final class CardFunctionalVerificationTests: XCTestCase {
    func testLiveCalDAVCard() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MCPHOST_CALDAV_FUNCTIONAL_E2E"] == "1")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.activate()
        let composer = app.textFields["chat.composer.input"].firstMatch
        XCTAssertTrue(composer.waitForExistence(timeout: 10))
        // Start from a fresh, already-loaded synthetic card; model tool selection is outside this test.
        let maximize = app.buttons["最大化"]
        XCTAssertTrue(maximize.waitForExistence(timeout: 10))
        maximize.tap()
        XCTAssertTrue(app.otherElements["Functional verification 0016"].firstMatch.waitForExistence(timeout: 10))
        for fixture in ["0016 Edit fixture", "0016 Copy fixture", "0016 Swipe fixture"] {
            XCTAssertTrue(app.staticTexts[fixture].firstMatch.waitForExistence(timeout: 5))
        }
        let add = app.buttons["リマインダーを追加"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(add.isHittable)
        XCTAssertLessThan(add.frame.maxY, app.frame.maxY)
        add.tap()
        let title = app.textFields["タイトル"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap()
        app.typeText("0016 Added fixture")
        dismissKeyboard(app)
        XCTAssertTrue(app.staticTexts["0016 Added fixture"].firstMatch.waitForExistence(timeout: 15))
        app.staticTexts["0016 Edit fixture"].firstMatch.tap()
        title.tap()
        title.press(forDuration: 1.2)
        app.menuItems["Select All"].tap()
        app.typeText("0016 Edited fixture")
        dismissKeyboard(app)
        saveDetail(app)
        XCTAssertTrue(app.staticTexts["0016 Edited fixture"].firstMatch.waitForExistence(timeout: 15))
        app.staticTexts["0016 Copy fixture"].firstMatch.tap()
        title.tap()
        title.press(forDuration: 1.2)
        app.menuItems["Select All"].tap()
        title.press(forDuration: 1.2)
        app.menuItems["Copy"].tap()
        dismissKeyboard(app)
        saveDetail(app)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 236, dy: 184)).tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "Tasks")).firstMatch.tap()
        XCTAssertFalse(app.staticTexts["0016 Edited fixture"].firstMatch.exists)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 70, dy: 184)).tap()
        app.buttons.matching(NSPredicate(format: "label == %@", "Functional verification 0016")).firstMatch.tap()
        let row = app.staticTexts["0016 Swipe fixture"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.swipeLeft()
        app.buttons["「0016 Swipe fixture」を削除"].tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row)
        waitForExpectations(timeout: 15)
        app.buttons["元のサイズに戻す"].tap()
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(composer.isHittable)
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        // Input accessory is English Done; the off-screen keyboard Done is Japanese.
        app.buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch.tap()
    }

    private func saveDetail(_ app: XCUIApplication) {
        // Xcode 27 drops WebView AX immediately after keyboard dismissal.
        // Screenshot-derived fallback is restricted to the documented 402x874 viewport.
        XCTAssertEqual(app.frame.size.width, 402)
        XCTAssertEqual(app.frame.size.height, 874)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 375, dy: 277)).tap()
    }
}

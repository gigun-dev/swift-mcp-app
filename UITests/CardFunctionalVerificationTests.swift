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
        if !app.buttons["元のサイズに戻す"].exists {
            XCTAssertTrue(app.buttons["最大化"].firstMatch.waitForExistence(timeout: 10))
            let maximize = app.buttons.matching(NSPredicate(format: "label == %@", "最大化")).allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(maximize)
            tapHittable(maximize!)
        }
        let candidates = app.webViews.allElementsBoundByIndex
        for view in candidates { print("CARD_CANDIDATE frame=\(view.frame) hittable=\(view.isHittable)") }
        guard let card = candidates.first(where: {
            $0.isHittable && $0.frame.width >= app.frame.width - 1 && $0.frame.minY >= 0 && $0.frame.maxY <= app.frame.maxY
        }) else { XCTFail("No foreground fullscreen WebView"); return }
        print("FULLSCREEN_CARD frame=\(card.frame) hittable=\(card.isHittable)")
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 236, dy: 184)).tap()
        let targetList = card.buttons.matching(NSPredicate(format: "label == %@", "Functional verification 0016")).firstMatch
        XCTAssertTrue(targetList.waitForExistence(timeout: 10))
        tapHittable(targetList)
        XCTAssertTrue(card.otherElements["functional-verification-0016"].firstMatch.waitForExistence(timeout: 10))
        for fixture in ["0016 Edit fixture", "0016 Copy fixture", "0016 Swipe fixture"] {
            XCTAssertTrue(card.staticTexts[fixture].firstMatch.waitForExistence(timeout: 5))
        }
        let add = card.buttons["リマインダーを追加"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 10))
        XCTAssertTrue(add.isHittable)
        XCTAssertLessThan(add.frame.maxY, app.frame.maxY)
        tapHittable(add)
        let title = card.textFields["タイトル"].firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        tapHittable(title)
        assertKeyboardVisibility(app, field: title, phase: "new-input")
        app.typeText("0016 Added fixture")
        dismissKeyboard(app)
        XCTAssertTrue(card.staticTexts["0016 Added fixture"].firstMatch.waitForExistence(timeout: 15))
        tapRow(card, row: card.staticTexts["0016 Edit fixture"].firstMatch)
        tapHittable(title)
        assertKeyboardVisibility(app, field: title, phase: "detail-input")
        title.press(forDuration: 1.2)
        tapHittable(app.menuItems["Select All"])
        app.typeText("0016 Edited fixture")
        dismissKeyboard(app)
        saveDetail(app)
        XCTAssertTrue(card.staticTexts["0016 Edited fixture"].firstMatch.waitForExistence(timeout: 15))
        tapRow(card, row: card.staticTexts["0016 Copy fixture"].firstMatch)
        tapHittable(title)
        title.press(forDuration: 1.2)
        tapHittable(app.menuItems["Select All"])
        title.press(forDuration: 1.2)
        tapHittable(app.menuItems["Copy"])
        dismissKeyboard(app)
        saveDetail(app)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 236, dy: 184)).tap()
        tapHittable(card.buttons.matching(NSPredicate(format: "label == %@", "Tasks")).firstMatch)
        expectation(for: NSPredicate(format: "hittable == false"), evaluatedWith: card.staticTexts["0016 Edited fixture"].firstMatch)
        waitForExpectations(timeout: 15)
        XCTAssertTrue(card.otherElements["Tasks"].firstMatch.isHittable)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 70, dy: 184)).tap()
        tapHittable(card.buttons.matching(NSPredicate(format: "label == %@", "Functional verification 0016")).firstMatch)
        let row = card.staticTexts["0016 Swipe fixture"].firstMatch
        revealRow(card, row: row)
        row.swipeLeft()
        tapHittable(card.buttons["「0016 Swipe fixture」を削除"])
        expectation(for: NSPredicate(format: "hittable == false"), evaluatedWith: row)
        waitForExpectations(timeout: 15)
        let lowerRow = card.staticTexts["ZZ 0016 scroll fixture 13"].firstMatch
        for _ in 0 ..< 4 where !lowerRow.isHittable { card.swipeUp() }
        XCTAssertTrue(lowerRow.isHittable)
        print("LOWER_ROW frame=\(lowerRow.frame)")
        XCTAssertGreaterThan(lowerRow.frame.minY, 500)
        tapHittable(lowerRow)
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        tapHittable(title)
        assertKeyboardVisibility(app, field: title, phase: "lower-row-input")
        dismissKeyboard(app)
        saveDetail(app)
        tapHittable(app.buttons["元のサイズに戻す"])
        XCTAssertTrue(composer.waitForExistence(timeout: 5))
        XCTAssertTrue(composer.isHittable)
    }

    private func revealRow(_ card: XCUIElement, row: XCUIElement) {
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        for _ in 0 ..< 6 where !row.isHittable {
            let bounds = card.frame
            let target = row.frame
            let header = card.descendants(matching: .any)
                .matching(NSPredicate(format: "label == %@", "Functional verification 0016")).firstMatch
            let visibleTop = header.isHittable ? header.frame.maxY + 8 : bounds.minY
            print("REVEAL row=\(target) visibleTop=\(visibleTop)")
            if target.maxY <= visibleTop {
                // Keep the drag inside card content; the sheet chrome has a different gesture owner.
                let start = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45))
                let end = card.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
                start.press(forDuration: 0.05, thenDragTo: end)
            } else if target.minY >= bounds.maxY {
                card.swipeUp()
            } else {
                // A visible but non-hittable row may still be loading; do not pull down the native sheet.
                break
            }
        }
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: row)
        waitForExpectations(timeout: 15)
    }

    private func tapRow(_ card: XCUIElement, row: XCUIElement) {
        revealRow(card, row: row)
        tapHittable(row)
    }

    private func tapHittable(_ element: XCUIElement) {
        expectation(for: NSPredicate(format: "hittable == true"), evaluatedWith: element)
        waitForExpectations(timeout: 15)
        element.tap()
    }

    private func assertKeyboardVisibility(_ app: XCUIApplication, field: XCUIElement, phase: String) {
        let keyboard = app.keyboards.firstMatch
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5))
        print("CARD_KEYBOARD phase=\(phase) keyboard=\(keyboard.frame) input=\(field.frame)")
        XCTAssertLessThan(keyboard.frame.minY, app.frame.maxY)
        XCTAssertLessThanOrEqual(field.frame.maxY, keyboard.frame.minY)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = phase
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    private func dismissKeyboard(_ app: XCUIApplication) {
        // Select the input accessory by its English Done label.
        tapHittable(app.buttons.matching(NSPredicate(format: "label == %@", "Done")).firstMatch)
    }

    private func saveDetail(_ app: XCUIApplication) {
        // Xcode 27 drops WebView AX immediately after keyboard dismissal.
        // Screenshot-derived fallback is restricted to the documented 402x874 viewport.
        XCTAssertEqual(app.frame.size.width, 402)
        XCTAssertEqual(app.frame.size.height, 874)
        app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 375, dy: 277)).tap()
    }
}

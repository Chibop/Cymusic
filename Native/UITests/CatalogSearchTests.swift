import XCTest

final class CatalogSearchTests: XCTestCase {
    private func openSearch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-app.language", "zh-Hans"]
        app.launch()
        app.tabBars.buttons["搜索"].tap()
        return app
    }

    func testSearchDoesNotRequireSourceAndKeepsTermAcrossTabs() {
        let app = openSearch()
        let submit = app.buttons["search.submit"], query = app.textFields["search.query"]
        XCTAssertTrue(query.waitForExistence(timeout: 5))
        XCTAssertFalse(submit.isEnabled)
        query.tap(); query.typeText("Adele")
        XCTAssertTrue(submit.isEnabled)
        app.tabBars.buttons["资料库"].tap(); app.tabBars.buttons["搜索"].tap()
        XCTAssertEqual(query.value as? String, "Adele")
        XCTAssertTrue(submit.isEnabled)
    }

    func testLanyueSearchAndReturnToAppleCatalog() {
        let app = openSearch()
        app.buttons["揽乐 Lanyue"].tap()
        let query = app.textFields["search.query"]
        query.tap(); query.typeText("Adele\n")
        let hit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search.result.'")).firstMatch
        XCTAssertTrue(hit.waitForExistence(timeout: 25))
        XCTAssertTrue(hit.label.contains("酷狗音乐"))
        hit.tap()
        XCTAssertTrue(app.navigationBars["选择音源"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.segmentedControls.buttons["Apple Music"].tap()
        XCTAssertFalse(hit.exists)
        XCTAssertEqual(query.value as? String, "Adele")
    }

    // The simulator fixture installs two scripts named Destination QA A and B.
    func testScriptTabsQueryEverySiteAndExposeTierActions() throws {
        let app = openSearch()
        app.textFields["search.query"].tap()
        app.textFields["search.query"].typeText("Adele Hello\n")
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search.result.'")).firstMatch
        try XCTSkipUnless(result.waitForExistence(timeout: 35), "Apple catalog unavailable")
        result.tap()
        let first = app.buttons["search.script.destination-qa-a"]
        let second = app.buttons["search.script.destination-qa-b"]
        try XCTSkipUnless(first.waitForExistence(timeout: 5) && second.exists, "Requires destination QA script fixtures")
        first.tap()
        for site in ["kg", "kw"] {
            XCTAssertTrue(app.buttons["search.play.\(site).128k"].waitForExistence(timeout: 12))
            XCTAssertTrue(app.buttons["search.download.\(site).320k"].exists)
        }
        second.tap()
        XCTAssertTrue(app.buttons["search.play.mg.128k"].waitForExistence(timeout: 12))
        XCTAssertFalse(app.buttons["search.play.kg.128k"].exists)
        app.buttons["search.play.mg.128k"].tap()
        XCTAssertTrue(app.staticTexts["search.playError.mg.128k"].waitForExistence(timeout: 10))
    }

    func testLiveCatalogResultNavigatesBackWithoutLosingResults() throws {
        let app = openSearch()
        let query = app.textFields["search.query"]
        query.tap(); query.typeText("Adele Hello\n")
        let result = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'search.result.'")).firstMatch
        try XCTSkipUnless(result.waitForExistence(timeout: 30), "Live Apple catalog did not return a song")
        let resultID = result.identifier
        result.tap()
        XCTAssertTrue(app.navigationBars["选择音源"].waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons[resultID].waitForExistence(timeout: 5))
        XCTAssertEqual(query.value as? String, "Adele Hello")
    }
}

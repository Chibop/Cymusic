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

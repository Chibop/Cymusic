import XCTest

final class NavigationTests: XCTestCase {
    func testLocalCoverFlowChangesPlayback() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-app.language", "zh-Hans"]
        app.launch()
        app.tabBars.buttons["资料库"].tap()
        let shuffle = app.buttons["library.shuffle"]
        try XCTSkipUnless(shuffle.waitForExistence(timeout: 5) && shuffle.isEnabled, "Requires local audio fixtures")
        app.buttons["library.openAlbum"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["library.albumDetail"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["关闭"].firstMatch.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.descendants(matching: .any)["library.albumDetail"].firstMatch)
        waitForExpectations(timeout: 5)
        shuffle.tap()
        XCTAssertFalse(app.buttons["mini.open"].exists)
        let lyric = app.staticTexts["library.lyric"]
        if lyric.waitForExistence(timeout: 1), lyric.label.hasPrefix("Fixture ") {
            let advanced = NSPredicate(format: "label == %@", "Fixture next")
            expectation(for: advanced, evaluatedWith: lyric)
            waitForExpectations(timeout: 12)
        }
        let flow = app.descendants(matching: .any)["library.coverflow"].firstMatch
        XCTAssertTrue(flow.waitForExistence(timeout: 5))
        let first = try XCTUnwrap(flow.value as? String)
        XCTAssertFalse(first.isEmpty)
        flow.coordinate(withNormalizedOffset: CGVector(dx: 0.78, dy: 0.5)).press(forDuration: 0.1, thenDragTo: flow.coordinate(withNormalizedOffset: CGVector(dx: 0.23, dy: 0.5)))
        let changed = NSPredicate(format: "value != %@ AND value != ''", first)
        expectation(for: changed, evaluatedWith: flow)
        waitForExpectations(timeout: 5)
    }

    func testNativeTabNavigation() throws {
        let app = XCUIApplication(); app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-app.language", "zh-Hans"]; app.launch()
        let settings = app.tabBars.buttons["设置"]
        XCTAssertEqual(app.tabBars.buttons.allElementsBoundByIndex.map(\.label), ["发现", "资料库", "搜索", "设置"])
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let sources = app.buttons["自定义音源"]
        XCTAssertTrue(sources.waitForExistence(timeout: 4)); sources.tap()
        XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).waitForExistence(timeout: 4))
        app.tabBars.buttons["搜索"].tap()
        XCTAssertTrue(app.tabBars.buttons["搜索"].isSelected)
        app.tabBars.buttons["发现"].tap()
        XCTAssertTrue(app.tabBars.buttons["发现"].isSelected)
        app.tabBars.buttons["资料库"].tap()
        XCTAssertTrue(app.tabBars.buttons["资料库"].isSelected)
    }
}

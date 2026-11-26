import XCTest

final class NavigationTests: XCTestCase {
    func testNativeTabNavigation() throws {
        let app = XCUIApplication(); app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-app.language", "zh-Hans"]; app.launch()
        let settings = app.tabBars.buttons["设置"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let sources = app.buttons["自定义音源"]
        XCTAssertTrue(sources.waitForExistence(timeout: 4)); sources.tap()
        XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).waitForExistence(timeout: 4))
        app.tabBars.buttons["发现"].tap()
        XCTAssertTrue(app.tabBars.buttons["发现"].isSelected)
        app.tabBars.buttons["资料库"].tap()
        XCTAssertTrue(app.tabBars.buttons["资料库"].isSelected)
    }
}

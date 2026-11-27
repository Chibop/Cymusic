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

    // Seed an MP3 (128 kbps) and a PCM WAV (24-bit/96 kHz) in importedLocalMusic.
    func testCollectionRowsShowFileQuality() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-app.language", "zh-Hans"]
        app.launch()
        app.tabBars.buttons["资料库"].tap()
        app.buttons["library.menu"].tap()
        app.buttons["全部歌曲"].tap()
        func row(_ title: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", title)).firstMatch
        }
        let mp3 = row("Shelf MP3"), pcm = row("Shelf PCM")
        try XCTSkipUnless(mp3.waitForExistence(timeout: 4) && pcm.exists, "Requires shelf quality fixtures")
        XCTAssertTrue(mp3.label.contains("MP3 · 128 kbps"), mp3.label)
        XCTAssertTrue(pcm.label.contains("高解析度无损 · PCM · 24-bit · 96 kHz"), pcm.label)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "MENU All Songs – indexed quality"; shot.lifetime = .keepAlways; add(shot)
    }

    // Seed importedLocalMusic with a track titled "Localization Fixture".
    func testChineseLibraryActionsWithEnglishPreferences() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-AppleLanguages", "(en-US)", "-AppleLocale", "en_US", "-app.language", "en"]
        app.launch()
        app.tabBars.buttons["资料库"].tap()
        XCTAssertEqual(app.buttons["library.menu"].label, "菜单")
        app.buttons["library.menu"].tap()
        app.buttons["全部歌曲"].tap()
        let actions = app.buttons["Localization Fixture 的操作"]
        try XCTSkipUnless(actions.waitForExistence(timeout: 4), "Requires Localization Fixture audio")
        actions.tap()
        XCTAssertTrue(app.buttons["添加到收藏"].exists)
        app.buttons["删除缓存歌曲"].tap()
        let alert = app.alerts["删除缓存歌曲？"]
        XCTAssertTrue(alert.staticTexts["Localization Fixture"].exists)
        XCTAssertTrue(alert.buttons["删除"].exists)
        alert.buttons["取消"].tap()
        XCTAssertTrue(actions.exists)
    }

    func testNativeTabNavigation() throws {
        let app = XCUIApplication(); app.launchArguments += ["-AppleLanguages", "(en-US)", "-AppleLocale", "en_US", "-app.language", "en"]; app.launch()
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

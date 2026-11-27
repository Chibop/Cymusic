import XCTest

final class NavigationTests: XCTestCase {
    func testMenuFiltersPlaylistAndQueueRoundTrip() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let menu = app.buttons["library.menu"]
        func choose(_ title: String) { menu.tap(); app.buttons[title].tap() }
        func row(_ title: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@ AND NOT label ENDSWITH %@", title, "的操作")).firstMatch
        }
        menu.tap()
        XCTAssertTrue(app.buttons["正在播放"].exists)
        XCTAssertFalse(app.buttons["正在播放"].isEnabled)
        app.buttons["全部歌曲"].tap()
        XCTAssertTrue(app.buttons["library.back"].exists)
        XCTAssertFalse(app.buttons["完成"].exists)
        let mp3 = row("Shelf MP3")
        try XCTSkipUnless(mp3.waitForExistence(timeout: 4), "Requires shelf fixture with timed lyric checkpoint: \(app.debugDescription)")
        mp3.tap()
        let flow = app.descendants(matching: .any)["library.coverflow"].firstMatch
        let lyric = app.staticTexts["library.lyric"]
        let checkpoint = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Menu checkpoint"), object: lyric)
        XCTAssertEqual(XCTWaiter.wait(for: [checkpoint], timeout: 12), .completed)
        app.buttons["library.center"].tap() // Pause at a nonzero lyric checkpoint.
        menu.tap()
        let first = app.buttons["我喜欢的"]
        XCTAssertLessThan(first.frame.midX, app.frame.midX)
        XCTAssertLessThan(first.frame.maxY, menu.frame.minY)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Wheel drawer inside bezel"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["关闭菜单"].tap()
        XCTAssertEqual(flow.value as? String, "Shelf MP3")
        XCTAssertEqual(lyric.label, "Menu checkpoint")
        choose("专辑列表")
        XCTAssertNotEqual(flow.value as? String, "Shelf MP3")
        choose("正在播放")
        XCTAssertEqual(flow.value as? String, "Shelf MP3")
        XCTAssertEqual(lyric.label, "Menu checkpoint")
        choose("我喜欢的")
        XCTAssertFalse(row("Shelf MP3").exists)
        XCTAssertTrue(app.staticTexts["暂无歌曲"].exists)
        app.buttons["library.toolbarMenu"].tap()
        XCTAssertTrue(app.buttons["完成"].exists)
        XCTAssertFalse(app.buttons["关闭菜单"].exists)
        app.buttons["全部歌曲"].tap()
        XCTAssertTrue(mp3.exists)
        let sheet = XCTAttachment(screenshot: app.screenshot())
        sheet.name = "Historical collections sheet"; sheet.lifetime = .keepAlways; add(sheet)
        app.buttons["完成"].tap()
        XCTAssertEqual(app.staticTexts["library.trackScope"].label, "我喜欢的音乐")
        XCTAssertFalse(mp3.exists)
        app.buttons["library.back"].tap()
        XCTAssertEqual(flow.value as? String, "Shelf MP3")
        XCTAssertEqual(lyric.label, "Menu checkpoint")
        choose("歌单列表")
        app.buttons["新建歌单"].tap()
        let alert = app.alerts["新建歌单"]
        alert.textFields.firstMatch.tap(); alert.textFields.firstMatch.typeText("Menu QA")
        alert.buttons["创建"].tap()
        let list = app.buttons["Menu QA"]
        list.tap()
        XCTAssertTrue(app.staticTexts["暂无歌曲"].exists)
        XCTAssertFalse(mp3.exists)
        XCTAssertFalse(app.buttons["完成"].exists)
        choose("歌单列表"); list.swipeLeft()
        if app.buttons["删除"].exists { app.buttons["删除"].tap() }
        XCTAssertTrue(list.waitForNonExistence(timeout: 4))
    }
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
        app.buttons["Shelf MP3 的操作"].tap()
        XCTAssertTrue(app.buttons["删除缓存歌曲"].exists)
        app.buttons["删除缓存歌曲"].tap()
        app.alerts.buttons["取消"].tap()
        XCTAssertTrue(mp3.exists)
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

    // Seed and verify with LegacyTests/cache-delete-fixture.py on a disposable simulator.
    func testCacheDeletionFromMenuAndAlbumSurvivesRelaunch() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        func openLibrary() { app.launch(); app.tabBars.buttons["资料库"].tap() }
        func collection() { app.buttons["library.menu"].firstMatch.tap(); app.buttons["全部歌曲"].firstMatch.tap() }
        func confirm(_ title: String) {
            app.buttons["删除缓存歌曲"].tap()
            let alert = app.alerts["删除缓存歌曲？"]
            XCTAssertTrue(alert.staticTexts[title].waitForExistence(timeout: 4))
            let button = alert.buttons["删除"]
            // On iOS 18 the accessibility alert appears before the sheet's
            // context-menu dismissal finishes and a tap is otherwise swallowed.
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: button)
            XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 4), .completed)
            button.tap()
            if !alert.waitForNonExistence(timeout: 1) && button.isHittable { button.tap() }
            XCTAssertTrue(alert.waitForNonExistence(timeout: 4))
        }
        openLibrary(); collection()
        let a = app.buttons["Cache Fixture A 的操作"], b = app.buttons["Cache Fixture B 的操作"]
        try XCTSkipUnless(a.waitForExistence(timeout: 3) && b.exists, "Requires cache deletion fixture")
        a.tap(); confirm("Cache Fixture A")
        XCTAssertTrue(a.waitForNonExistence(timeout: 4), app.debugDescription); XCTAssertTrue(b.exists)
        app.buttons["library.back"].tap(); app.buttons["library.openAlbum"].tap()
        let track = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Cache Fixture B")).firstMatch
        XCTAssertTrue(track.waitForExistence(timeout: 5)); track.press(forDuration: 1)
        confirm("Cache Fixture B"); XCTAssertFalse(track.exists)
        app.terminate(); openLibrary(); collection()
        XCTAssertFalse(a.exists); XCTAssertFalse(b.exists)
        XCTAssertTrue(app.buttons["Cache Fixture Original 的操作"].exists)
    }

    func testNativeTabNavigation() throws {
        let app = XCUIApplication(); app.launchArguments += ["-AppleLanguages", "(en-US)", "-AppleLocale", "en_US", "-app.language", "en"]; app.launch()
        let settings = app.tabBars.buttons["设置"]
        XCTAssertEqual(app.tabBars.buttons.allElementsBoundByIndex.map(\.label), ["资料库", "搜索", "设置"])
        XCTAssertTrue(settings.waitForExistence(timeout: 10)); settings.tap()
        let sources = app.buttons["自定义音源"]
        XCTAssertTrue(sources.waitForExistence(timeout: 4)); sources.tap()
        XCTAssertTrue(app.navigationBars.buttons.element(boundBy: 0).waitForExistence(timeout: 4))
        app.tabBars.buttons["搜索"].tap()
        XCTAssertTrue(app.tabBars.buttons["搜索"].isSelected)
        XCTAssertFalse(app.tabBars.buttons["发现"].exists)
        app.tabBars.buttons["资料库"].tap()
        XCTAssertTrue(app.tabBars.buttons["资料库"].isSelected)
    }
}

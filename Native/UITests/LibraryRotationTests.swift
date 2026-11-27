import XCTest

final class LibraryRotationTests: XCTestCase {
  private func openLibrary() -> XCUIApplication {
    continueAfterFailure = false
    XCUIDevice.shared.orientation = .portrait
    addTeardownBlock { XCUIDevice.shared.orientation = .portrait }
    let app = XCUIApplication()
    app.launchArguments += ["-AppleLanguages", "(zh-Hans)", "-app.language", "zh-Hans"]
    app.launch()
    app.tabBars.buttons["资料库"].tap()
    return app
  }

  func testLandscapeHidesChromeAndRestoresLibrary() {
    let app = openLibrary()
    for orientation in [UIDeviceOrientation.landscapeLeft, .landscapeRight] {
      XCUIDevice.shared.orientation = orientation
      XCTAssertTrue(app.buttons["library.landscape.playPause"].waitForExistence(timeout: 5))
      XCTAssertFalse(app.tabBars.firstMatch.exists)
      XCTAssertFalse(app.navigationBars.firstMatch.exists)
      XCTAssertFalse(app.buttons["library.menu"].exists)
      XCTAssertFalse(app.buttons["library.shuffle"].exists)
    }
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(app.buttons["library.menu"].waitForExistence(timeout: 5))
    XCTAssertTrue(app.buttons["library.import"].isHittable)
    XCTAssertTrue(app.tabBars.buttons["资料库"].isSelected)
  }

  // Seed Documents/importedLocalMusic with multiple tracks, each with an LRC
  // containing [00:00.00]Opening and [00:03.00]Rotation checkpoint.
  func testRotationPreservesPlayingTrackAndLyricPosition() throws {
    let app = openLibrary()
    let shuffle = app.buttons["library.shuffle"]
    try XCTSkipUnless(shuffle.isEnabled, "Requires local rotation audio fixtures")
    shuffle.tap()
    let lyric = app.staticTexts["library.lyric"]
    let checkpoint = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "Rotation checkpoint"), object: lyric)
    try XCTSkipUnless(XCTWaiter.wait(for: [checkpoint], timeout: 10) == .completed, "Requires rotation LRC fixture")
    app.buttons["library.playPause"].tap()
    let shelf = app.descendants(matching: .any)["library.coverflow"].firstMatch
    let track = try XCTUnwrap(shelf.value as? String)
    attach("Portrait")
    XCUIDevice.shared.orientation = .landscapeLeft
    let play = app.buttons["library.landscape.playPause"]
    XCTAssertTrue(play.waitForExistence(timeout: 5))
    XCTAssertEqual(lyric.label, "Rotation checkpoint")
    XCTAssertEqual(shelf.value as? String, track)
    XCTAssertEqual(shelf.frame.width, app.frame.width, accuracy: 2)
    attach("Landscape")
    play.tap()
    XCUIDevice.shared.orientation = .portrait
    XCTAssertTrue(app.buttons["library.next"].waitForExistence(timeout: 5))
    XCTAssertEqual(shelf.value as? String, track)
    XCTAssertEqual(lyric.label, "Rotation checkpoint")
    app.buttons["library.next"].tap()
    XCTAssertNotEqual(shelf.value as? String, track)
  }

  private func attach(_ name: String) {
    let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
    attachment.name = name
    attachment.lifetime = .keepAlways
    add(attachment)
  }
}

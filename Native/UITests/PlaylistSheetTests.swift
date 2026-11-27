import XCTest

// Install the app, then run scripts/fixtures/playlist-sheet.py UDID on a disposable simulator.
final class PlaylistSheetTests: XCTestCase {
  func testBatchSelectionAndArtworkSurviveRelaunch() throws {
    continueAfterFailure = false
    let app = XCUIApplication()
    let name = "Sheet " + String(UUID().uuidString.prefix(6))
    func openSheet() {
      app.launch()
      app.tabBars.buttons["资料库"].tap()
      app.buttons["library.toolbarMenu"].tap()
    }
    func track(_ n: Int) -> XCUIElement {
      app.buttons["library.track.legacy:importedLocalMusic/Playlist QA/QA Track \(n).mp3"]
    }
    func color(_ image: UIImage, _ x: CGFloat, _ y: CGFloat) -> String {
      let size = image.size
      let point = CGPoint(x: -size.width * x, y: -size.height * y)
      let pixel = UIGraphicsImageRenderer(size: CGSize(width: 1, height: 1)).image { _ in image.draw(at: point) }
      var bytes = [UInt8](repeating: 0, count: 4)
      let ctx = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
      ctx.draw(pixel.cgImage!, in: CGRect(x: 0, y: 0, width: 1, height: 1))
      return bytes.prefix(3).map { $0 > 155 ? "1" : "0" }.joined()
    }
    func quadrants() -> [String] {
      let art = app.descendants(matching: .any).matching(identifier: "歌单封面").firstMatch.screenshot().image
      return [(0.25,0.25), (0.75,0.25), (0.25,0.75), (0.75,0.75)].map { color(art, $0.0, $0.1) }
    }
    openSheet()
    XCTAssertTrue(track(1).waitForExistence(timeout: 8), app.debugDescription)
    XCTAssertTrue(track(1).label.contains("128 kbps"))
    let row = track(1).screenshot().image
    XCTAssertEqual(color(row, 23 / row.size.width, 0.5), "100")
    app.buttons["新建歌单"].tap()
    app.alerts.textFields.firstMatch.typeText(name)
    app.alerts.buttons["创建"].tap()
    app.buttons[name].tap()
    XCTAssertTrue(app.staticTexts["暂无歌曲"].exists)
    let add = app.buttons["playlist.addSongs"]
    XCTAssertLessThan(add.frame.midX, app.frame.midX)
    add.tap()
    app.buttons["QA Ensemble"].tap()
    app.buttons["取消"].tap()
    XCTAssertTrue(app.staticTexts["暂无歌曲"].exists)
    add.tap()
    app.buttons["QA Ensemble"].tap()
    app.segmentedControls.buttons["全部歌曲"].tap()
    track(5).tap()
    app.buttons["playlist.confirm"].tap()
    for n in 1...5 { XCTAssertTrue(track(n).exists) }
    let colors = quadrants()
    XCTAssertEqual(Set(colors), ["100", "010", "001", "110"])
    add.tap()
    XCTAssertFalse(app.buttons["QA Ensemble"].isEnabled)
    XCTAssertFalse(app.buttons["playlist.confirm"].isEnabled)
    app.buttons["取消"].tap()
    app.terminate()
    openSheet()
    app.buttons[name].tap()
    for n in 1...5 { XCTAssertTrue(track(n).exists) }
    XCTAssertEqual(quadrants(), colors)
  }
}

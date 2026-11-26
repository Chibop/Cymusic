#if ARTWORK_TESTS && os(macOS)
// Copy this file, ArtworkCatalog.swift, Library.swift, LegacyMigration.swift and App/Song.swift
// into Sources/ alongside the LegacyTests/Harness.swiftmanifest package (as Package.swift),
// link Vendor/MMKV as MMKV, then swift run -Xswiftc -DARTWORK_TESTS Probe [--live].
import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

@main struct ArtworkTests {
  static func sample(_ red: CGFloat) -> Data {
    let ctx = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    ctx.setFillColor(red: red, green: 0, blue: 0, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
    let bytes = NSMutableData(); let out = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(out, ctx.makeImage()!, nil); precondition(CGImageDestinationFinalize(out)); return bytes as Data
  }
  @MainActor static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let docs = root.appendingPathComponent("Documents"), base = root.appendingPathComponent("Library")
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    let original = docs.appendingPathComponent("original.png"), bytes = sample(0.5); try bytes.write(to: original)
    let audio = docs.appendingPathComponent("track.wav")
    // 44-byte WAVE header and a frame of 8-bit PCM silence.
    try Data([82,73,70,70,38,0,0,0,87,65,86,69,102,109,116,32,16,0,0,0,1,0,1,0,64,31,0,0,64,31,0,0,1,0,8,0,100,97,116,97,2,0,0,0,128,128]).write(to: audio)
    let a = Song(id: "a", title: "One", artist: "A", artwork: original, album: "Álbum", albumArtist: "VA")
    var b = a; b.id = "b"; b.artist = "B"; b.album = " album "
    var c = a; c.id = "c"; c.albumArtist = "Other"
    let lib = Library(documents: docs, directory: base)
    for song in [a,b,c] { lib.registerCache(song, audio) }; await lib.indexLocalFiles()
    lib.favorite(b); lib.importPlaylist("Mix", songs: [c,b,a]); let listID = lib.playlists[0].id
    try await lib.replaceArtwork(for: a, albumMode: false, data: sample(0))
    let single = lib.artworkOverride(for: a)!
    try await lib.replaceArtwork(for: b, albumMode: true, data: sample(1))
    let album = lib.artworkOverride(for: b)!
    do { try await lib.replaceArtwork(for: b, albumMode: true, data: Data("<html/>".utf8)); fatalError("invalid data accepted") } catch {}
    for test in [lib, Library(documents: docs, directory: base)] {
      precondition(single != album && test.albumArtwork(for: a) == album && test.artworkOverride(for: a) == single)
      precondition(test.localTracks(["a","b","c"]).compactMap(\.artwork) == [single,album,original])
      precondition(test.favorites.map(\.id) == ["b"] && test.playlists[0].id == listID && test.playlists[0].songIDs == ["c","b","a"])
      precondition(test.favorites[0].artwork == album && test.artworkOverride(for: c) == nil)
    }
    let persisted = try JSONSerialization.jsonObject(with: Data(contentsOf: base.appendingPathComponent("library.json"))) as! [String: Any]
    precondition((persisted["songs"] as! [[String:Any]]).allSatisfy { $0["artwork"] as? String == original.absoluteString })
    let preserved = try Data(contentsOf: original); precondition(preserved == bytes)
    print("PASS: album scope, independent song override, original files and metadata, favorites, playlist order, image rejection, offline relaunch")
    if CommandLine.arguments.contains("--live") {
      for albumMode in [true,false] {
        let page = try await ArtworkCatalog.search(albumMode ? "Daft Punk Discovery" : "Daft Punk One More Time", albumMode: albumMode)
        let first = page.candidates.first!; let art = try await ArtworkCatalog.download(first)
        try await lib.replaceArtwork(for: a, albumMode: albumMode, data: art)
        let file = albumMode ? lib.albumArtwork(for: a)! : lib.artworkOverride(for: a)!
        precondition(CGImageSourceCreateWithURL(file as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) } != nil)
        print("PASS live \(albumMode ? "album" : "song"): \(page.country) · \(page.candidates.count) candidates · \(first.title) · \(art.count) bytes")
      }
    }
  }
}
#endif

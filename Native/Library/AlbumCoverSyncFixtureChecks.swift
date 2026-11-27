#if ALBUM_COVER_SYNC_TESTS && os(macOS)
// From Native, stage App/Song.swift, Library/{Library,LegacyMigration,ArtworkCatalog,AlbumCoverSync*}.swift
// in the LegacyTests/Harness.swiftmanifest package as Sources, symlink Vendor/MMKV as MMKV,
// and run swift run -Xswiftc -DALBUM_COVER_SYNC_TESTS Probe.
import AppKit

@main struct AlbumCoverSyncFixtureChecks {
  @MainActor static func image(_ color: NSColor) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 96, pixelsHigh: 96,
      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
      bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    ctx.setFillColor(color.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 96, height: 96))
    return rep.representation(using: .png, properties: [:])!
  }

  @MainActor static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let docs = root.appendingPathComponent("Documents"), base = root.appendingPathComponent("Library")
    try FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
    let audio = docs.appendingPathComponent("track.wav")
    try Data([82,73,70,70,38,0,0,0,87,65,86,69,102,109,116,32,16,0,0,0,1,0,1,0,64,31,0,0,64,31,0,0,1,0,8,0,100,97,116,97,2,0,0,0,128,128]).write(to: audio)
    let lib = Library(documents: docs, directory: base)
    let songs = ["Álbum", " album ", "Empty", "Search", "Download", "Invalid", "", "Last"].enumerated().map {
      Song(id: String($0.offset), title: "Track \($0.offset)", artist: "Guest", album: $0.element, albumArtist: "VA")
    }
    for song in songs { lib.registerCache(song, audio) }
    await lib.indexLocalFiles()
    lib.favorite(Song(id: "remote", title: "Remote", artist: "Guest", album: "Remote"))
    let old = image(.blue), fresh = image(.red)
    for song in songs { try await lib.replaceArtwork(for: song, albumMode: true, data: old) }
    try await lib.replaceArtwork(for: songs[0], albumMode: false, data: image(.green))
    let single = lib.artworkOverride(for: songs[0])!, original = lib.albumArtwork(for: songs[0])!
    var events: [String] = []
    let sync = lib.albumCoverSync
    let task = sync.start(library: lib, search: { query in
      events.append(query)
      if query == "Search VA" { throw URLError(.timedOut) }
      let ids: [Int64] = query == "Empty VA" ? [] : [query == "Invalid VA" ? 3 : query == "Download VA" ? 2 : 1, 9]
      return .init(candidates: ids.map { .init(id: $0, title: query, detail: "", thumbnail: URL(string: "https://a.mzstatic.com/art")!) }, country: "CN")
    }, download: { candidate in
      events.append("download \(candidate.id)")
      if candidate.id == 2 { throw URLError(.badServerResponse) }
      return candidate.id == 3 ? Data("broken".utf8) : fresh
    }, pause: { events.append("pace") })
    let duplicate = sync.start(library: lib, search: { _ in fatalError("duplicate batch") })
    precondition(duplicate == task)
    await task.value
    precondition(events == ["Álbum VA", "download 1", "pace", "Empty VA", "pace", "Search VA", "pace", "Download VA", "download 2", "pace", "Invalid VA", "download 3", "pace", "Last VA", "download 1"])
    let p = sync.progress
    precondition(p.phase == .finished && p.total == 7 && p.updated == 2 && p.skipped == 2 && p.failed == 3)
    let reloaded = Library(documents: docs, directory: base)
    let updated = reloaded.albumArtwork(for: songs[0])!
    precondition(updated != original && reloaded.artworkOverride(for: songs[0]) == single)
    precondition(reloaded.artworkOverride(for: songs[1]) == updated && reloaded.albumArtwork(for: songs[7]) == updated)
    for song in songs[2...6] { precondition(reloaded.albumArtwork(for: song) == original) }
    let revision = lib.artworkRevision
    await sync.start(library: lib, search: { _ in
      sync.cancel()
      return .init(candidates: [], country: "CN")
    }).value
    precondition(sync.progress.phase == .cancelled && sync.progress.processed == 0 && sync.progress.total == 7)
    precondition(lib.artworkRevision == revision)
    print("PASS: unique local albums, first result, sequential pacing, duplicate tap, honest counts, cancellation, error preservation, song override and offline reload")
  }
}
#endif

#if ALBUM_COVER_SYNC_TESTS && os(macOS)
// Requires ffmpeg on PATH. From Native, stage App/{Song,LanguageSettings}.swift,
// Library/{Library,LegacyMigration,ArtworkCatalog,AlbumCoverSync*}.swift
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
    let old = image(.blue), fresh = image(.red)
    let local = docs.appendingPathComponent("custom.png"), broken = docs.appendingPathComponent("bad.png")
    try old.write(to: local); try Data("corrupt".utf8).write(to: broken)
    let embedded = docs.appendingPathComponent("attached.mp3")
    let encoder = Process()
    encoder.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    encoder.arguments = ["ffmpeg", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc", "-i", local.path,
      "-t", "0.2", "-map", "0:a", "-map", "1:v", "-c:v", "copy", "-id3v2_version", "3", embedded.path]
    try encoder.run(); encoder.waitUntilExit(); precondition(encoder.terminationStatus == 0)
    let titles = ["Álbum", " album ", "Empty", "Search", "Download", "Invalid", "", "Last", "Album override",
      "Sibling", "Sibling", "Tagged", "Tagged", "Local", "Remote", "Cached", "Race", "Search race", "Stale"]
    var songs = titles.enumerated().map {
      Song(id: String($0.offset), title: "Track \($0.offset)", artist: "Guest", album: $0.element, albumArtist: "VA")
    }
    songs[0].artwork = URL(string: "http://example.com/default.jpg")
    songs[7].artwork = broken
    songs[13].artwork = local
    songs[18].artwork = docs.appendingPathComponent("absent.jpg")
    for (i, song) in songs.enumerated() { lib.registerCache(song, i == 12 ? embedded : audio) }
    await lib.indexLocalFiles()
    lib.favorite(Song(id: "remote", title: "Remote", artist: "Guest", album: "Not local"))
    try await lib.replaceArtwork(for: songs[8], albumMode: true, data: old)
    try await lib.replaceArtwork(for: songs[10], albumMode: false, data: image(.green))
    let single = lib.artworkOverride(for: songs[10])!, original = lib.albumArtwork(for: songs[8])!
    // Seed an uncached catalog URL and a cached-only image without contacting any host.
    let index = base.appendingPathComponent("library.json")
    var json = try JSONSerialization.jsonObject(with: Data(contentsOf: index)) as! [String: Any]
    var records = json["songs"] as! [[String: Any]]
    records[14]["artwork"] = "https://art.invalid/cover.jpg"
    json["songs"] = records; json["cachedArt"] = ["15": "cached.png"]
    try old.write(to: base.appendingPathComponent("cached.png"))
    try JSONSerialization.data(withJSONObject: json).write(to: index, options: .atomic)
    let library = Library(documents: docs, directory: base)
    var events: [String] = []
    let sync = library.albumCoverSync
    let task = sync.start(library: library, search: { query in
      events.append(query)
      if query == "Search race VA" { try await library.replaceArtwork(for: songs[17], albumMode: true, data: old) }
      if query == "Search VA" { throw URLError(.timedOut) }
      let ids: [Int64] = query == "Empty VA" ? [] : [query == "Invalid VA" ? 3 : query == "Download VA" ? 2 : 1, 9]
      return .init(candidates: ids.map { .init(id: $0, title: query, detail: "", thumbnail: URL(string: "https://a.mzstatic.com/art")!) }, country: "CN")
    }, download: { candidate in
      events.append("download \(candidate.id)")
      if candidate.title == "Race VA" { try await library.replaceArtwork(for: songs[16], albumMode: true, data: old) }
      if candidate.id == 2 { throw URLError(.badServerResponse) }
      return candidate.id == 3 ? Data("broken".utf8) : fresh
    }, pause: { events.append("pace") })
    let duplicate = sync.start(library: library, search: { _ in fatalError("duplicate batch") })
    precondition(duplicate == task)
    await task.value
    precondition(events == ["Álbum VA", "download 1", "pace", "Empty VA", "pace", "Search VA", "pace", "Download VA", "download 2", "pace", "Invalid VA", "download 3", "pace", "Last VA", "download 1", "pace", "Race VA", "download 1", "pace", "Search race VA", "pace", "Stale VA", "download 1"])
    let p = sync.progress
    precondition(p.phase == .finished && p.total == 16 && p.updated == 3 && p.skipped == 10 && p.failed == 3)
    let reloaded = Library(documents: docs, directory: base)
    let updated = reloaded.albumArtwork(for: songs[0])!
    precondition(updated != original && reloaded.artworkOverride(for: songs[1]) == updated)
    for i in [7, 18] { precondition(reloaded.albumArtwork(for: songs[i]) == updated) }
    for i in [8, 16, 17] { precondition(reloaded.albumArtwork(for: songs[i]) == original) }
    precondition(reloaded.artworkOverride(for: songs[10]) == single && reloaded.albumArtwork(for: songs[9]) == nil)
    precondition(reloaded.albumArtwork(for: songs[12])?.isFileURL == true && reloaded.artworkOverride(for: songs[12]) == nil)
    for i in 2...6 { precondition(reloaded.albumArtwork(for: songs[i]) == nil) }
    let revision = library.artworkRevision
    await sync.start(library: library, search: { query in
      precondition(query == "Empty VA") // populated on the previous run: skip without searching
      sync.cancel()
      return .init(candidates: [], country: "CN")
    }).value
    precondition(sync.progress.phase == .cancelled && sync.progress.processed == 1 && sync.progress.total == 16)
    precondition(library.artworkRevision == revision)
    print("PASS: 16 local albums, 3 filled, 10 skipped, 3 failed; sibling, embedded, local, remote, cached and override art protected; placeholders, stale files, races, pacing, cancellation and reload verified")
  }
}
#endif

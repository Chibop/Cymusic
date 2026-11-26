import Foundation

/// Metadata only: intentionally no asset URL, artwork, account, or playback history.
struct AppleLibraryTrack: Codable, Identifiable {
    let persistentID: UInt64
    let albumPersistentID: UInt64
    let title: String
    let artist: String
    let albumTitle: String
    let albumArtist: String
    let duration: Double?
    let disc: Int
    let track: Int
    let cloudOnly: Bool

    var id: String { "apple-library:\(persistentID)" }
    var song: Song {
        // The library ID is device-local, NOT a store ID. The pool must match by metadata.
        Song(id: id, title: title, artist: artist, platform: "apple-library", album: albumTitle,
             albumArtist: albumArtist, duration: duration)
    }
    var canMatch: Bool { !title.isEmpty && !artist.isEmpty }
    var albumKey: String {
        if albumPersistentID != 0 { return "album:\(albumPersistentID)" }
        guard !albumTitle.isEmpty else { return "unfiled:\(id)" }
        let credit = albumArtist.isEmpty ? artist : albumArtist
        return "tags:\(albumTitle.utf8.count):\(albumTitle)\(credit)"
    }
}

struct AppleLibraryAlbum: Identifiable {
    let id: String
    let tracks: [AppleLibraryTrack]
    var title: String { tracks.first?.albumTitle ?? "" }
    var artist: String { tracks.first?.albumArtist ?? "" }
}

struct AppleLibrarySnapshot: Codable {
    let tracks: [AppleLibraryTrack]
    let syncedAt: Date
    init(rows: [AppleLibraryTrack], now: Date = Date()) {
        var seen = Set<UInt64>()
        tracks = rows.filter { $0.persistentID != 0 && seen.insert($0.persistentID).inserted }
            .sorted { a, b in
                let order = a.title.localizedStandardCompare(b.title)
                return order == .orderedSame ? a.persistentID < b.persistentID : order == .orderedAscending
            }
        syncedAt = now
    }
    var albums: [AppleLibraryAlbum] {
        Dictionary(grouping: tracks, by: \.albumKey).map { key, rows in
            AppleLibraryAlbum(id: key, tracks: rows.sorted { ($0.disc, $0.track, $0.title, $0.persistentID) < ($1.disc, $1.track, $1.title, $1.persistentID) })
        }.sorted { a, b in
            let order = a.title.localizedStandardCompare(b.title)
            return order == .orderedSame ? a.id < b.id : order == .orderedAscending
        }
    }
}

struct AppleLibraryDisk {
    let directory: URL
    private var file: URL { directory.appendingPathComponent("library-v1.json") }
    func load() throws -> AppleLibrarySnapshot? {
        do { return try JSONDecoder().decode(AppleLibrarySnapshot.self, from: Data(contentsOf: file)) }
        catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
    }
    func save(_ snapshot: AppleLibrarySnapshot) throws {
        var folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var flags = URLResourceValues(); flags.isExcludedFromBackup = true
        try folder.setResourceValues(flags)
        try JSONEncoder().encode(snapshot).write(to: file, options: [.atomic, .completeFileProtection])
    }
}

import Foundation
import MMKV

@MainActor
enum LegacyMigration {
    static let storeID = "appPersistStatus"
    static let audioFolders = ["importedLocalMusic", "download/music", "musicCache"]
    private static let libraryKeys = ["music.favorites", "music.playLists", "music.importedLocalMusic"]
    private static let invalid = CocoaError(.fileReadCorruptFile)

    // MMKV's default root on Apple can be Documents/mmkv. Never initialize
    // with nil, and never pass the original path to ANY MMKV API.
    private static func values(documents: URL, keys: [String]) throws -> [String: String]? {
        let fm = FileManager.default
        let root = documents.appendingPathComponent("mmkv")
        let temp = fm.temporaryDirectory.appendingPathComponent("CymusicMigration-" + UUID().uuidString)
        try fm.createDirectory(at: temp, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: temp) }
        for name in [storeID, storeID + ".crc"] {
            let file = root.appendingPathComponent(name)
            let attrs: [FileAttributeKey: Any]
            do { attrs = try fm.attributesOfItem(atPath: file.path) }
            catch let e as CocoaError where e.code == .fileReadNoSuchFile && name == storeID { return nil }
            guard root.resolvingSymlinksInPath().path == documents.resolvingSymlinksInPath().appendingPathComponent("mmkv").path,
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  let size = (attrs[.size] as? NSNumber)?.intValue,
                  (4096...64 * 1024 * 1024).contains(size), size % 4096 == 0 else { throw invalid }
            // Write independent bytes, not hard links or copied symlinks.
            let data = try Data(contentsOf: file)
            guard data.count == size else { throw invalid }
            try data.write(to: temp.appendingPathComponent(name), options: .withoutOverwriting)
        }
        // In Core 2.4.0 writeActualSize stores the current length in
        // MMKVMetaInfo for v3/v4. isFileValid still checks the old 4-byte
        // header. Mirror that length ONLY on the scratch copy before the CRC
        // check; otherwise valid, recently appended databases fail validation.
        let metadata = try Data(contentsOf: temp.appendingPathComponent(storeID + ".crc"))
        let version = metadata.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
        guard version <= 4 else { throw invalid }
        if version >= 3 {
            let handle = try FileHandle(forWritingTo: temp.appendingPathComponent(storeID))
            defer { try? handle.close() }
            try handle.write(contentsOf: metadata[28..<32])
        }
        MMKV.initialize(rootDir: temp.path, logLevel: .none)
        guard MMKV.isFileValid(for: storeID, rootPath: temp.path),
              let db = MMKV(mmapID: storeID, cryptKey: nil, rootPath: temp.path, mode: .readOnly, expectedCapacity: 0) else { throw invalid }
        defer { db.close() }
        var result: [String: String] = [:]
        for key in keys where db.contains(key: key) {
            guard let value = db.string(forKey: key) else { throw invalid }
            result[key] = value
        }
        return result
    }

    // Inert MMKV JSON strings for the source owner. Never install, execute,
    // fetch, or select scripts as a side effect of loading the library.
    static func sourceSettings(documents: URL) throws -> [String: String]? {
        try values(documents: documents, keys: ["music.musicApi", "music.selectedMusicApi"])
    }

    struct Result {
        var songs: [Song] = []
        var favoriteIDs: [String] = []
        var playlists: [Library.Playlist] = []
        var paths: [String: String] = [:]
    }

    static func library(documents: URL) throws -> Result? {
        guard let values = try values(documents: documents, keys: libraryKeys), !values.isEmpty else { return nil }
        typealias Record = [String: Any]
        func records(_ key: String) throws -> [Record] {
            guard let raw = values[key] else { return [] }
            guard let rows = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [Record] else { throw invalid }
            return rows
        }
        func remote(_ value: Any?) -> URL? {
            guard let raw = value as? String, let url = URL(string: raw),
                  ["https", "http"].contains(url.scheme?.lowercased()), url.host != nil else { return nil }
            return url
        }
        var result = Result(), byID: [String: Int] = [:]
        func ingest(_ row: Record) throws -> String {
            let rawID = row["id"] as? String ?? (row["id"] as? NSNumber)?.stringValue
            guard let id = rawID, !id.isEmpty else { throw invalid }
            let platform = row["platform"] as? String
            let song = Song(id: id, title: row["title"] as? String ?? row["name"] as? String ?? id,
                            artist: row["artist"] as? String ?? row["singer"] as? String ?? "Unknown Artist",
                            url: remote(row["url"]), artwork: remote(row["artwork"]), platform: platform, lyrics: row["rawLrc"] as? String)
            if let i = byID[id] {
                // Native Song.id is also the provider lookup ID. Do not prefix
                // or silently combine two different providers' records.
                guard result.songs[i].platform == platform else { throw invalid }
            } else { byID[id] = result.songs.count; result.songs.append(song) }
            if let raw = row["url"] as? String, let path = audioPath(raw, documents: documents) { result.paths[id] = path }
            return id
        }
        func membership(_ rows: [Record]) throws -> [String] {
            var seen = Set<String>()
            return try rows.map(ingest).filter { seen.insert($0).inserted }
        }
        _ = try membership(records("music.importedLocalMusic"))
        result.favoriteIDs = try membership(records("music.favorites"))
        for list in try records("music.playLists") {
            guard let name = list["name"] as? String ?? list["title"] as? String, !name.isEmpty,
                  let songs = list["songs"] as? [Record] else { throw invalid }
            result.playlists.append(.init(name: name, songIDs: try membership(songs)))
        }
        return result
    }

    private static func audioPath(_ raw: String, documents: URL) -> String? {
        let path: String
        if raw.hasPrefix("file://"), let url = URL(string: raw), url.isFileURL { path = url.path }
        else if raw.hasPrefix("/") { path = raw } else { return nil }
        let parts = path.components(separatedBy: "/")
        guard !parts.contains(".."), !parts.contains("."), let i = parts.lastIndex(of: "Documents") else { return nil }
        let relative = parts.dropFirst(i + 1).joined(separator: "/")
        guard audioFolders.contains(where: { relative.hasPrefix($0 + "/") }) else { return nil }
        let canonical = documents.resolvingSymlinksInPath().appendingPathComponent(relative)
        guard canonical.resolvingSymlinksInPath().path == canonical.path,
              (try? canonical.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return relative
    }
}

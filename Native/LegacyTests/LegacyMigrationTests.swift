import Foundation
import MMKV

// Standalone integration test. Run using run.sh; every file belongs to the fixture.
@main @MainActor struct MigrationTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        let docs = root.appendingPathComponent("Documents")
        let folder = docs.appendingPathComponent("mmkv")
        let audio = docs.appendingPathComponent("importedLocalMusic/song.mp3")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try fm.createDirectory(at: audio.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: audio)
        MMKV.initialize(rootDir: root.appendingPathComponent("runtime").path)
        func writeFixture(_ playlists: String) {
            let db = MMKV(mmapID: "appPersistStatus", rootPath: folder.path)!
            defer { db.sync(); db.close() }
            precondition(db.set(#"[{"id":"mid","title":"远方","platform":"QQ"},{"id":"mid","platform":"QQ"}]"#, forKey: "music.favorites"))
            precondition(db.set(playlists, forKey: "music.playLists"))
            precondition(db.set(#"[{"id":"offline","platform":"local","artist":"歌手","title":"Track","url":"file:///old/Documents/importedLocalMusic/song.mp3"}]"#, forKey: "music.importedLocalMusic"))
            precondition(db.set(#"[{"id":"src","script":"throw 1"}]"#, forKey: "music.musicApi"))
            precondition(db.set(#"{"id":"src"}"#, forKey: "music.selectedMusicApi"))
        }
        let index = root.appendingPathComponent("native")
        func open() -> Library { Library(documents: docs, directory: index) }
        let existing = open()
        existing.createPlaylist("Native")
        writeFixture("bad json")
        let saved = index.appendingPathComponent("library.json")
        let before = try Data(contentsOf: saved)
        precondition(open().message != nil)
        let afterFailure = try Data(contentsOf: saved)
        precondition(before == afterFailure)
        writeFixture(#"[{"name":"Road","songs":[{"id":"offline","platform":"local"},{"id":"mid","platform":"QQ"}]}]"#)
        let pair = ["appPersistStatus", "appPersistStatus.crc"].map { folder.appendingPathComponent($0) }
        let bytes = try pair.map { try Data(contentsOf: $0) }
        let settings = try LegacyMigration.sourceSettings(documents: docs)
        precondition(settings?["music.selectedMusicApi"] == #"{"id":"src"}"# && settings?["music.musicApi"]?.contains("throw 1") == true)
        let library = open()
        precondition(library.message == nil, library.message ?? "")
        precondition(library.favorites.map(\.id) == ["mid"] && library.favorites.first?.title == "远方")
        precondition(library.playlists.map(\.name) == ["Native", "Road"])
        let tracks = library.songs(for: library.playlists[1].songIDs)
        precondition(tracks.map(\.title) == ["Track", "远方"] && tracks.first?.artist == "歌手")
        precondition(tracks.first?.url?.standardizedFileURL.path == audio.standardizedFileURL.path && library.songs.count == 2, "tracks=\(library.songs) expected=\(audio)")
        let original = try pair.map { try Data(contentsOf: $0) }
        precondition(original == bytes)
        try checkCacheDeletion(root.appendingPathComponent("deletion"))
        library.deletePlaylist(library.playlists[1].id)
        library.favorite(library.favorites[0])
        var damaged = bytes[0]; damaged[10] ^= 1
        try damaged.write(to: pair[0]); precondition(open().message == nil && open().favorites.isEmpty && open().playlists.count == 1)
        let retry = root.appendingPathComponent("retry")
        precondition(Library(documents: docs, directory: retry).message != nil)
        try bytes[0].write(to: pair[0]); try Data([0]).write(to: pair[1])
        precondition(Library(documents: docs, directory: retry).message != nil)
        try bytes[1].write(to: pair[1]); precondition(Library(documents: docs, directory: retry).favorites.count == 1)
        try Data([0xff]).write(to: saved); precondition(open().message != nil)
        let preserved = try Data(contentsOf: saved); precondition(preserved == Data([0xff]))
        print("PASS: official MMKV fixture, retry, native merge, file relocation, source strings, original bytes, one-time marker, corrupt input and index")
    }

    static func checkCacheDeletion(_ root: URL) throws {
        let fm = FileManager.default, docs = root.appendingPathComponent("Documents")
        let support = root.appendingPathComponent("Support"), index = support.appendingPathComponent("Index")
        let audio = support.appendingPathComponent("PlaybackCache/shared/audio.wav")
        let lrc = audio.deletingPathExtension().appendingPathExtension("lrc")
        let external = docs.appendingPathComponent("Original.wav")
        for directory in [docs, audio.deletingLastPathComponent()] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        for file in [audio, lrc, external] { try Data([1]).write(to: file) }
        func open() -> Library { Library(documents: docs, directory: index) }
        let library = open(), a = Song(id: "a", title: "A", artist: "Test", platform: "fixture")
        var b = a; b.id = "b"
        library.registerCache(a, audio); library.registerCache(b, audio)
        library.favorite(a); library.importPlaylist("Pair", songs: [a,b]); library.removeCachedTrack(a)
        precondition(library.localSongs.map(\.id) == [b.id] && fm.fileExists(atPath: lrc.path))
        library.removeCachedTrack(b); library.removeCachedTrack(b)
        let reopened = open()
        precondition(reopened.localSongs.isEmpty && reopened.favorites.map(\.id) == [a.id])
        precondition(reopened.playlists.first?.songIDs == [a.id,b.id])
        precondition(!fm.fileExists(atPath: audio.path) && !fm.fileExists(atPath: lrc.path))
        try Data([2]).write(to: audio); try fm.createSymbolicLink(at: lrc, withDestinationURL: external)
        reopened.registerCache(a, audio); reopened.removeCachedTrack(a)
        precondition(fm.fileExists(atPath: external.path) && fm.fileExists(atPath: lrc.path))
        reopened.registerCache(b, external); reopened.removeCachedTrack(b)
        precondition(fm.fileExists(atPath: external.path) && open().localSongs.isEmpty && reopened.message == nil)
        print("PASS: shared cache, lyric ownership and symlink, external file, idempotent deletion, reopened memberships")
    }
}

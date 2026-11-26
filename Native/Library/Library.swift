import Foundation
import Combine
import UniformTypeIdentifiers

@MainActor
final class Library: ObservableObject {
    struct Playlist: Codable, Identifiable {
        var id = UUID()
        var name: String
        var songIDs: [String] = []
    }

    private struct Store: Codable {
        var version = 1
        var songs: [Song] = []
        var favoriteIDs: [String] = []
        var playlists: [Playlist] = []
        // Paths relative to Documents survive app container relocation.
        var documentsPaths: [String: String] = [:]
    }

    @Published private var store = Store()
    @Published var message: String?
    @Published private(set) var importing = false
    private var loadFailure: String?
    private let documents: URL
    private let index: URL

    init(documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
         directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CymusicLibrary")) {
        self.documents = documents
        index = directory.appendingPathComponent("library.json")
        do {
            store = try JSONDecoder().decode(Store.self, from: Data(contentsOf: index))
            guard store.version == 1 else { throw CocoaError(.fileReadUnknown) }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            recoverLegacyFiles()
        } catch {
            loadFailure = "Could not load the library. The saved file has been preserved. \(error.localizedDescription)"
            message = loadFailure
        }
    }

    var songs: [Song] { store.songs.map(resolved) }
    var favorites: [Song] { songs(for: store.favoriteIDs) }
    var playlists: [Playlist] { store.playlists }

    func songs(for ids: [String]) -> [Song] {
        let lookup = Dictionary(store.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.compactMap { lookup[$0].map(resolved) }
    }

    private func resolved(_ song: Song) -> Song {
        guard let path = store.documentsPaths[song.id] else { return song }
        let local = documents.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: local.path) || song.url == nil else { return song }
        var value = song
        value.url = local
        return value
    }

    func isFavorite(_ song: Song) -> Bool { store.favoriteIDs.contains(song.id) }

    func favorite(_ song: Song) {
        var next = store
        if isFavorite(song) {
            next.favoriteIDs.removeAll { $0 == song.id }
        } else {
            remember(song, in: &next)
            next.favoriteIDs.append(song.id)
        }
        save(next)
    }

    func registerCache(_ song: Song, _ file: URL) {
        guard file.isFileURL, (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            message = "Cached audio is unavailable: \(file.lastPathComponent)"
            return
        }
        var next = store
        remember(song, in: &next)
        let prefix = documents.resolvingSymlinksInPath().path + "/"
        let path = file.resolvingSymlinksInPath().path
        if path.hasPrefix(prefix) {
            next.documentsPaths[song.id] = String(path.dropFirst(prefix.count))
        } else if let i = next.songs.firstIndex(where: { $0.id == song.id }) {
            next.documentsPaths.removeValue(forKey: song.id)
            next.songs[i].url = file
        }
        save(next)
    }

    private func remember(_ song: Song, in state: inout Store) {
        if !state.songs.contains(where: { $0.id == song.id }) { state.songs.append(song) }
    }

    func createPlaylist(_ name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        guard !playlists.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame }) else {
            message = "A playlist with that name already exists."
            return
        }
        var next = store
        next.playlists.append(Playlist(name: name))
        save(next)
    }

    func importPlaylist(_ name: String, songs: [Song]) {
        var next = store
        var list = Playlist(name: name)
        var seen = Set<String>()
        for song in songs where seen.insert(song.id).inserted {
            remember(song, in: &next); list.songIDs.append(song.id)
        }
        next.playlists.append(list); save(next)
    }

    func deletePlaylist(_ id: UUID) {
        var next = store
        next.playlists.removeAll { $0.id == id }
        save(next)
    }

    func add(_ song: Song, to id: UUID) {
        var next = store
        guard let i = next.playlists.firstIndex(where: { $0.id == id }), !next.playlists[i].songIDs.contains(song.id) else { return }
        remember(song, in: &next)
        next.playlists[i].songIDs.append(song.id)
        save(next)
    }

    func remove(_ song: Song, from id: UUID) {
        var next = store
        guard let i = next.playlists.firstIndex(where: { $0.id == id }) else { return }
        next.playlists[i].songIDs.removeAll { $0 == song.id }
        save(next)
    }

    @discardableResult private func save(_ next: Store) -> Bool {
        if let loadFailure { message = loadFailure; return false }
        do {
            try FileManager.default.createDirectory(at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(next).write(to: index, options: .atomic)
            store = next
            return true
        } catch {
            message = "Could not save library: \(error.localizedDescription)"
            return false
        }
    }

    // The RN store kept metadata in MMKV but its audio files need no decoder.
    private func recoverLegacyFiles() {
        var next = Store()
        for folder in ["importedLocalMusic", "download/music", "musicCache"] {
            let root = documents.appendingPathComponent(folder)
            let fm = FileManager.default
            guard fm.fileExists(atPath: root.path), let entries = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in entries {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
                      UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true else { continue }
                let path = folder + "/" + String(url.path.dropFirst(root.path.count + 1))
                let song = Song(id: "legacy:" + path, title: url.deletingPathExtension().lastPathComponent, artist: "Unknown Artist", platform: "local")
                next.songs.append(song)
                next.documentsPaths[song.id] = path
            }
        }
        if !next.songs.isEmpty { save(next) }
    }

    func importFiles(_ urls: [URL]) async {
        guard !importing else { return }
        if let loadFailure { message = loadFailure; return }
        importing = true
        defer { importing = false }
        let folder = documents.appendingPathComponent("Imported Music")
        var failures: [String] = []
        var imported: [(Song, URL)] = []
        for source in urls {
            do {
                let file = try await Task.detached(priority: .userInitiated) { try Self.copyAudio(source, to: folder) }.value
                let song = Song(id: "local:" + file.lastPathComponent, title: source.deletingPathExtension().lastPathComponent, artist: "Unknown Artist", platform: "local")
                imported.append((song, file))
            } catch { failures.append("\(source.lastPathComponent): \(error.localizedDescription)") }
        }
        var next = store
        for (song, file) in imported {
            next.songs.append(song)
            next.documentsPaths[song.id] = "Imported Music/" + file.lastPathComponent
        }
        if !imported.isEmpty && !save(next) {
            for (_, file) in imported { try? FileManager.default.removeItem(at: file) }
            return
        }
        if !failures.isEmpty { message = failures.joined(separator: "\n") }
    }

    private nonisolated static func copyAudio(_ source: URL, to folder: URL) throws -> URL {
        let granted = source.startAccessingSecurityScopedResource()
        defer { if granted { source.stopAccessingSecurityScopedResource() } }
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(source.pathExtension)
        var coordinationError: NSError?
        var result: Result<Void, Error> = .failure(CocoaError(.fileReadUnknown))
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { url in
            result = Result {
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
                guard values.isRegularFile == true, values.contentType?.conforms(to: .audio) == true else { throw CocoaError(.fileReadUnsupportedScheme) }
                try manager.copyItem(at: url, to: destination)
            }
        }
        do {
            if let coordinationError { throw coordinationError }
            try result.get()
            return destination
        } catch {
            try? manager.removeItem(at: destination)
            throw error
        }
    }
}

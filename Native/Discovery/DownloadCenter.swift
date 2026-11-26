import Foundation
import Combine

/// App-owned queue: navigating away from a playlist does not cancel its transfers.
@MainActor final class DownloadCenter: ObservableObject {
    struct Key: Hashable {
        let platform: String?
        let id: String
        init(_ song: Song) { platform = song.platform; id = song.id }
    }
    private let engine: SourceEngine
    private let library: Library
    private var queue: [Song] = []
    private var worker: Task<Void, Never>?
    @Published private(set) var pending: Set<Key> = []
    @Published private(set) var failures: [Key: String] = [:]
    @Published private(set) var total = 0

    init(engine: SourceEngine, library: Library) { self.engine = engine; self.library = library }

    private func valid(_ file: URL?) -> URL? {
        guard let file, file.isFileURL,
              (try? FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType) == .typeRegular else { return nil }
        return file
    }
    private func indexed(_ song: Song) -> URL? {
        valid(library.localSongs.first { $0.id == song.id && $0.platform == song.platform }?.url)
    }
    func localFile(_ song: Song) -> URL? {
        indexed(song) ?? valid(song.url) ?? valid(PlaybackFiles.existing(song))
    }
    func enqueue(_ songs: [Song]) {
        var added = [Song]()
        for song in songs {
            let key = Key(song)
            guard !pending.contains(key) else { continue }
            if let file = localFile(song) {
                if indexed(song) == nil { library.registerCache(song, file) }
                continue
            }
            pending.insert(key); failures[key] = nil; added.append(song)
        }
        guard !added.isEmpty else { return }
        total = (worker == nil ? 0 : total) + added.count
        queue.append(contentsOf: added)
        if worker == nil { worker = Task(priority: .utility) { await drain() } }
    }
    private func drain() async {
        while !queue.isEmpty {
            let song = queue.removeFirst(), key = Key(song)
            defer { pending.remove(key) }
            do {
                if let file = localFile(song) {
                    if indexed(song) == nil { library.registerCache(song, file) }
                    continue
                }
                let media = try await engine.downloadMedia(song) { source in
                    try await PlaybackFiles.save(song, source: source)
                }
                var saved = song
                saved.audioSource = media.source; saved.quality = media.quality
                if let lyrics = try? await SourceCatalog.lyrics(media.match),
                   PlaybackLyric.parse(lyrics).contains(where: { $0.time != nil }) { saved.lyrics = lyrics }
                library.registerCache(saved, media.url)
                if indexed(song) == nil { throw CocoaError(.fileWriteUnknown) }
            } catch { failures[key] = error.localizedDescription }
        }
        worker = nil
    }
}

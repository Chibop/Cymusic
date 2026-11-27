import Combine
import Foundation

@MainActor
final class AlbumCoverSync: ObservableObject {
  enum Phase { case idle, running, cancelling, cancelled, finished }

  struct Progress {
    var phase = Phase.idle
    var total = 0, updated = 0, skipped = 0, failed = 0
    var currentAlbum = ""
    var processed: Int { updated + skipped + failed }
  }

  @Published private(set) var progress = Progress()
  private var job: Task<Void, Never>?

  @discardableResult
  func start(
    library: Library,
    search: @escaping (String) async throws -> ArtworkCatalog.ResultPage = {
      try await ArtworkCatalog.search($0, albumMode: true)
    },
    download: @escaping (ArtworkCatalog.Candidate) async throws -> Data = ArtworkCatalog.download,
    pause: @escaping () async throws -> Void = { try await Task.sleep(for: .seconds(3)) }
  ) -> Task<Void, Never> {
    if let job { return job }
    progress = Progress(phase: .running)
    let task = Task {
      // Embedded covers and album identity may still be indexing on launch.
      await library.indexLocalFiles()
      var seen = Set<String>()
      let albums = library.localSongs.compactMap { song -> (String, Song)? in
        let key = library.albumArtworkKey(for: song)
        return seen.insert(key).inserted ? (key, song) : nil
      }
      progress.total = albums.count
      var madeRequest = false
      for (key, song) in albums {
        guard !Task.isCancelled else { break }
        let title = (song.album ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, library.needsAlbumArtwork(key) else { progress.skipped += 1; continue }
        progress.currentAlbum = title
        let artist = (song.albumArtist ?? song.artist).trimmingCharacters(in: .whitespacesAndNewlines)
        let query = [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
        do {
          if madeRequest {
            try await pause()
            try Task.checkCancellation()
            guard library.needsAlbumArtwork(key) else { progress.skipped += 1; continue }
          }
          try Task.checkCancellation()
          madeRequest = true
          let page = try await search(query)
          try Task.checkCancellation()
          guard let first = page.candidates.first, library.needsAlbumArtwork(key) else { progress.skipped += 1; continue }
          let data = try await download(first)
          try Task.checkCancellation()
          if try await library.replaceArtwork(for: song, albumMode: true, data: data, ifMissingAlbum: key) {
            progress.updated += 1
          } else { progress.skipped += 1 }
        } catch {
          if Task.isCancelled { break }
          progress.failed += 1
        }
      }
      progress.currentAlbum = ""
      progress.phase = Task.isCancelled ? .cancelled : .finished
      job = nil
    }
    job = task
    return task
  }

  func cancel() {
    guard let job else { return }
    progress.phase = .cancelling
    job.cancel()
  }
}

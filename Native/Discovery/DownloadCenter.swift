import Foundation
import Combine
import AVFoundation
import UniformTypeIdentifiers

/// URLSession's async download convenience can coalesce delegate updates. Own the
/// download task so byte counts and the temporary file come from the same GET.
private final class TransferObserver: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let update: @Sendable (Int64, Int64?) -> Void
    let result: AsyncThrowingStream<(URL, URLResponse), Error>.Continuation
    init(update: @escaping @Sendable (Int64, Int64?) -> Void,
         result: AsyncThrowingStream<(URL, URLResponse), Error>.Continuation) {
        self.update = update; self.result = result
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response else { throw URLError(.badServerResponse) }
            let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.moveItem(at: location, to: temp)
            if case .terminated = result.yield((temp, response)) { try? FileManager.default.removeItem(at: temp) }
        } catch { result.finish(throwing: error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        result.finish(throwing: error)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite expected: Int64) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else { return }
        update(totalBytesWritten, expected > 0 ? expected : nil)
    }

    static func download(_ request: URLRequest, update: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> (URL, URLResponse) {
        let (stream, continuation) = AsyncThrowingStream<(URL, URLResponse), Error>.makeStream()
        let observer = TransferObserver(update: update, result: continuation)
        let session = URLSession(configuration: .default, delegate: observer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.downloadTask(with: request).resume()
        for try await result in stream { return result }
        try Task.checkCancellation()
        throw URLError(.badServerResponse)
    }
}

/// One durable, foreground worker. The head remains in the journal until its
/// file is indexed, so suspension and cancellation never discard unfinished work.
@MainActor final class DownloadCenter: ObservableObject {
    struct Key: Hashable {
        let platform: String?
        let id: String
        init(_ song: Song) { platform = song.platform; id = song.id }
    }
    private struct Job: Codable {
        let song: Song
        let best: Bool
        var routes: [String: Set<String>]?
        var retries = 0
    }
    private struct State: Codable {
        var jobs = [Job]()
        var paused = false
        var after: Date?
        var appleDownloadRoutes: [String: Set<String>]?
        var batchTotal: Int?
        var completed: Int?
    }
    private let engine: SourceEngine
    private let library: Library
    private let journal: URL
    private struct Recording: Hashable {
        let title, artist: String
        init(_ song: Song) { title = song.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(); artist = song.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
    }
    private var byID = [Key: Song]()
    private var byRecording = [Recording: [Song]]()
    private var observation: AnyCancellable?
    private var state = State()
    private var worker: Task<Void, Never>?
    @Published private(set) var pending: Set<Key> = []
    @Published private(set) var failures: [Key: String] = [:]
    @Published private(set) var total = 0
    @Published private(set) var isPaused = false
    @Published private(set) var retryAfter: Date?

    @Published private(set) var appleDownloadRoutes: [String: Set<String>]?
    @Published private(set) var completed = 0
    @Published private(set) var receivedBytes: Int64 = 0
    @Published private(set) var expectedBytes: Int64?
    private var activeTransfer: UUID?
    private var activeKey: Key?

    func setAppleDownloadRoutes(_ value: [String: Set<String>]?) {
        appleDownloadRoutes = value
        state.appleDownloadRoutes = value
        persist()
    }
    func enqueueApple(_ songs: [Song]) { append(songs, best: true, routes: appleDownloadRoutes) }
    func progress(for song: Song) -> Double? {
        guard activeKey == Key(song), let expectedBytes, expectedBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }

    init(engine: SourceEngine, library: Library, journal: URL? = nil) {
        self.engine = engine; self.library = library
        self.journal = journal ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cymusic/download-queue.json")
        do { state = try JSONDecoder().decode(State.self, from: Data(contentsOf: self.journal)) }
        catch let e as CocoaError where e.code == .fileReadNoSuchFile { }
        catch { library.message = error.localizedDescription }
        pending = Set(state.jobs.map { Key($0.song) }); total = state.batchTotal ?? state.jobs.count
        completed = state.completed ?? 0
        appleDownloadRoutes = state.appleDownloadRoutes
        isPaused = state.paused; retryAfter = state.after
        observation = library.$localSongs.sink { [weak self] songs in
            self?.byID = Dictionary(songs.map { (Key($0), $0) }, uniquingKeysWith: { lhs, _ in lhs })
            self?.byRecording = Dictionary(grouping: songs, by: Recording.init)
        }
        start()
    }

    private func persist() {
        do {
            try FileManager.default.createDirectory(at: journal.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: journal, options: .atomic)
        } catch { library.message = error.localizedDescription }
    }
    private func valid(_ file: URL?) -> URL? {
        guard let file, file.isFileURL,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
        return file
    }
    private func indexed(_ song: Song) -> URL? {
        valid(byID[Key(song)]?.url)
    }
    func localFile(_ song: Song) -> URL? {
        if let exact = indexed(song) ?? valid(song.url) ?? valid(PlaybackFiles.existing(song)) { return exact }
        // Fast prefilter before the version/ISRC/duration/ambiguity checks.
        let candidates = byRecording[Recording(song)] ?? []
        return valid(PoolMatcher.match(song, in: candidates)?.url)
    }
    func enqueue(_ songs: [Song]) { append(songs, best: false) }
    func enqueueBest(_ songs: [Song]) { append(songs, best: true) }
    private func append(_ songs: [Song], best: Bool, routes: [String: Set<String>]? = nil) {
        var added = 0
        let fresh = state.jobs.isEmpty
        for song in songs where !pending.contains(Key(song)) {
            let key = Key(song)
            failures[key] = nil
            if let file = localFile(song) {
                // A cross-ID match already has a library row: don't create a second one.
                if indexed(song) == nil && !library.localSongs.contains(where: { $0.url == file }) { library.registerCache(song, file) }
                continue
            }
            pending.insert(key); state.jobs.append(Job(song: song, best: best, routes: routes)); added += 1
        }
        guard added > 0 else { return }
        if fresh { completed = 0; state.completed = 0 }
        total = (fresh ? 0 : total) + added
        state.batchTotal = total
        persist(); start()
    }
    func pause() { isPaused = true; state.paused = true; persist(); worker?.cancel() }
    func resume() {
        isPaused = false; state.paused = false
        if !state.jobs.isEmpty { state.jobs[0].retries = 0 }
        persist(); start()
    }
    func stop() {
        worker?.cancel(); state.jobs.removeAll(); pending.removeAll(); total = 0
        completed = 0; state.completed = 0; state.batchTotal = 0
        resetProgress()
        isPaused = false; state.paused = false; persist() // Keep the server's cooldown.
    }
    private func resetProgress() {
        activeTransfer = nil; activeKey = nil; receivedBytes = 0; expectedBytes = nil
    }
    private func start() {
        guard worker == nil, !isPaused, !state.jobs.isEmpty else { return }
        worker = Task(priority: .utility) { await drain() }
    }
    private func drain() async {
        defer { worker = nil; start() }
        while !Task.isCancelled, !isPaused, let job = state.jobs.first {
            let key = Key(job.song)
            defer { resetProgress() }
            do {
                while let after = state.after, after > Date() {
                    try await Task.sleep(nanoseconds: UInt64(min(60, max(0, after.timeIntervalSinceNow)) * 1e9))
                }
                try Task.checkCancellation()
                state.after = nil; retryAfter = nil
                // Also pace boundaries between two scopes/songs.
                try await Task.sleep(nanoseconds: 650_000_000)
                let scope = BulkHTTP()
                try await BulkHTTP.$current.withValue(scope) { try await transfer(job, scope: scope) }
                try Task.checkCancellation()
                failures[key] = nil
                completed += 1; state.completed = completed
            } catch let error as BulkHTTP.Throttled {
                // The whole queue stops at a 429, not just this script/quality.
                // Long server deadlines are honored even across manual resume/relaunch.
                let delay = max(error.retryAfter ?? 0, [2.0, 4.0, 8.0][min(job.retries, 2)])
                state.after = Date().addingTimeInterval(delay); retryAfter = state.after
                if !Task.isCancelled, !state.jobs.isEmpty {
                    state.jobs[0].retries += 1
                    if state.jobs[0].retries > 2 || delay > 120 {
                        failures[key] = error.localizedDescription; state.paused = true; isPaused = true
                    }
                }
                persist(); continue
            } catch {
                guard !Task.isCancelled else { return }
                failures[key] = error.localizedDescription
            }
            pending.remove(key); state.jobs.removeFirst(); persist()
        }
    }
    /// PlaybackFiles' legacy transfer API discards the response headers. Preserve
    /// its cache layout and audio validation, but inspect this *same* GET (no probe).
    nonisolated static func saveQueued(_ song: Song, from source: URL, progress: @escaping @Sendable (Int64, Int64?) -> Void = { _, _ in }) async throws -> URL {
        if let existing = PlaybackFiles.existing(song) { return existing }
        guard ProviderSession.webURL(source.absoluteString) != nil, source.pathExtension.lowercased() != "m3u8" else { throw PlaybackFiles.CacheError.unsupported }
        var request = URLRequest(url: source)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (temp, response) = try await TransferObserver.download(request, update: progress)
        defer { try? FileManager.default.removeItem(at: temp) }
        try BulkHTTP.check(response)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), http.statusCode != 206 else { throw URLError(.badServerResponse) }
        let size = Int64(try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard size > 0 else { throw URLError(.zeroByteResource) }
        let encoded = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        if (encoded == nil || encoded == "identity"), response.expectedContentLength >= 0, size != response.expectedContentLength {
            throw URLError(.cannotDecodeContentData)
        }
        let mime = response.mimeType ?? ""
        guard !mime.contains("mpegurl"), !mime.hasPrefix("text/") else { throw PlaybackFiles.CacheError.unsupported }
        let extensions = ["mp3", "m4a", "mp4", "aac", "flac", "wav", "aiff", "aif", "caf", "alac", "ogg", "opus"]
        let ext = [response.url?.pathExtension, source.pathExtension, UTType(mimeType: mime)?.preferredFilenameExtension]
            .compactMap { $0?.lowercased() }.first(where: extensions.contains) ?? "mp3"
        var folder = PlaybackFiles.folder(song)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true; try folder.setResourceValues(values)
        let stage = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        try FileManager.default.moveItem(at: temp, to: stage)
        defer { try? FileManager.default.removeItem(at: stage) }
        guard try await !AVURLAsset(url: stage).loadTracks(withMediaType: .audio).isEmpty else { throw PlaybackFiles.CacheError.unsupported }
        try Task.checkCancellation()
        if let existing = PlaybackFiles.existing(song) { return existing }
        let file = folder.appendingPathComponent("audio").appendingPathExtension(ext)
        try FileManager.default.moveItem(at: stage, to: file)
        return file
    }
    private func transfer(_ job: Job, scope: BulkHTTP) async throws {
        let song = job.song
        if let file = localFile(song) {
            if indexed(song) == nil && !library.localSongs.contains(where: { $0.url == file }) { library.registerCache(song, file) }
            return
        }
        let save: (URL) async throws -> URL = { [self] source in
            try await scope.pace()
            let token = UUID()
            self.activeTransfer = token; self.activeKey = Key(song)
            self.receivedBytes = 0; self.expectedBytes = nil
            defer { self.resetProgress() }
            return try await Self.saveQueued(song, from: source) { [weak self] received, expected in
                Task { @MainActor in
                    guard let self, self.activeTransfer == token, received >= self.receivedBytes else { return }
                    self.receivedBytes = received; self.expectedBytes = expected
                }
            }
        }
        let media = job.best ? try await engine.downloadBestMedia(song, routes: job.routes, save: save) : try await engine.downloadMedia(song, save: save)
        var saved = song
        saved.audioSource = media.source; saved.quality = media.quality
        // Lyrics are optional. A lyric 429 still governs the next queued item.
        if !PlaybackLyric.parse(saved.lyrics).contains(where: { $0.time != nil }) {
            do {
                try await scope.pace()
                if let lyrics = try await SourceEngine.downloadLyrics(media.match), PlaybackLyric.parse(lyrics).contains(where: { $0.time != nil }) { saved.lyrics = lyrics }
            } catch { /* Preserve the validated audio even if metadata fails. */ }
        }
        library.registerCache(saved, media.url)
        try scope.check()
        guard indexed(song) != nil else { throw CocoaError(.fileWriteUnknown) }
    }
}

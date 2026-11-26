import AVFoundation
import AudioToolbox
import Combine
import CryptoKit
import Foundation
import ImageIO
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
    var legacyMMKVImported: Bool?
    var songs: [Song] = []
    var favoriteIDs: [String] = []
    var playlists: [Playlist] = []
    // Paths relative to Documents survive app container relocation.
    var documentsPaths: [String: String] = [:]
    var externalFiles: [String: URL]?
    var removedCacheIDs: Set<String>?
    var supportPaths: [String: String]?
    var media: [String: DiskMedia]?
    var cachedArt: [String: String]?
  }

  @Published private var store = Store()
  @Published private(set) var localSongs: [Song] = []
  private var indexing = false
  private var needsIndex = false
  @Published var message: String?
  @Published private(set) var importing = false
  private var loadFailure: String?
  private let documents: URL
  private let index: URL

  init(
    documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0],
    directory: URL = FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent(
        "CymusicLibrary")
  ) {
    self.documents = documents
    index = directory.appendingPathComponent("library.json")
    do {
      store = try JSONDecoder().decode(Store.self, from: Data(contentsOf: index))
      guard store.version == 1 else { throw CocoaError(.fileReadUnknown) }
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      // No saved index yet.
    } catch {
      loadFailure =
        "Could not load the library. The saved file has been preserved. \(error.localizedDescription)"
      message = loadFailure
    }
    if loadFailure == nil { recoverLegacyFiles() }
    migrateLegacyLibrary()
    rebuildLocalProjection()
    scheduleIndex()
  }

  private func migrateLegacyLibrary() {
    guard loadFailure == nil, store.legacyMMKVImported != true else { return }
    do {
      guard let legacy = try LegacyMigration.library(documents: documents) else { return }
      var next = store
      var existing = Dictionary(
        next.songs.enumerated().map { ($0.element.id, $0.offset) },
        uniquingKeysWith: { first, _ in first })
      var aliases: [String: String] = [:]
      for song in legacy.songs {
        let path = legacy.paths[song.id]
        // Upgrade the older filename-only recovery entry in place so
        // existing native memberships still point at the same track.
        if existing[song.id] == nil, let path, let i = existing["legacy:" + path] {
          var upgraded = song
          upgraded.id = next.songs[i].id
          next.songs[i] = upgraded
          aliases[song.id] = upgraded.id
        } else if let i = existing[song.id] {
          guard next.songs[i].platform == song.platform else {
            throw CocoaError(.fileReadCorruptFile)
          }
        } else {
          existing[song.id] = next.songs.count
          next.songs.append(song)
        }
        let id = aliases[song.id] ?? song.id
        if next.documentsPaths[id] == nil { next.documentsPaths[id] = path }
      }
      var favorites = Set(next.favoriteIDs)
      for key in legacy.favoriteIDs {
        let id = aliases[key] ?? key
        if favorites.insert(id).inserted { next.favoriteIDs.append(id) }
      }
      for var list in legacy.playlists {
        var seen = Set<String>()
        list.songIDs = list.songIDs.map { aliases[$0] ?? $0 }.filter { seen.insert($0).inserted }
        next.playlists.append(list)
      }
      next.legacyMMKVImported = true
      save(next)
    } catch {
      message =
        "Legacy library import could not finish. It will retry on next launch. \(error.localizedDescription)"
    }
  }

  var songs: [Song] { store.songs.map(resolved) }
  var favorites: [Song] { songs(for: store.favoriteIDs) }
  var playlists: [Playlist] { store.playlists }

  func songs(for ids: [String]) -> [Song] {
    let lookup = Dictionary(
      store.songs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
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

  // Preserve remote memberships for migration and online player actions. The library UI
  // consumes only this projection, never the catalog/store records directly.
  func localTracks(_ ids: [String]) -> [Song] {
    let lookup = Dictionary(localSongs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return ids.compactMap { lookup[$0] }
  }
  var localFavorites: [Song] { localTracks(store.favoriteIDs) }
  func trackOrder(_ song: Song) -> (Int, Int) {
    let info = store.media?[song.id]
    return (info?.disc ?? 1, info?.track ?? Int.max)
  }
  private func localFile(_ song: Song) -> URL? {
    func valid(_ file: URL?) -> URL? {
      guard let file, file.isFileURL,
        (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
      else { return nil }
      return file
    }
    guard store.removedCacheIDs?.contains(song.id) != true else { return nil }
    if let path = store.documentsPaths[song.id],
      let file = valid(documents.appendingPathComponent(path))
    {
      return file
    }
    let support = index.deletingLastPathComponent().deletingLastPathComponent()
    if let path = store.supportPaths?[song.id],
      let file = valid(support.appendingPathComponent(path))
    {
      return file
    }
    if let file = valid(store.externalFiles?[song.id]) { return file }
    if let file = valid(song.url) { return file }
    #if os(iOS)
      if let file = valid(PlaybackFiles.existing(song)) { return file }
    #endif
    // Upgrade absolute paths saved by older native versions after container relocation.
    if let url = song.url, url.isFileURL, let i = url.pathComponents.lastIndex(of: "PlaybackCache")
    {
      return valid(support.appendingPathComponent(url.pathComponents[i...].joined(separator: "/")))
    }
    return nil
  }
  private func rebuildLocalProjection() {
    localSongs = store.songs.compactMap { original in
      guard let file = localFile(original) else { return nil }
      var song = original
      song.url = file
      song.quality = nil
      if let cover = store.cachedArt?[song.id] {
        song.artwork = index.deletingLastPathComponent().appendingPathComponent(cover)
      }
      if let m = store.media?[song.id] {
        song.lyrics = song.lyrics ?? m.lyrics
        song.title = m.title ?? song.title
        song.artist = m.artist ?? song.artist
        song.album = m.album ?? song.album
        song.albumArtist = m.albumArtist ?? song.albumArtist
        song.duration = m.duration ?? song.duration
        song.quality = m.badge
        if let cover = m.cover {
          song.artwork = index.deletingLastPathComponent().appendingPathComponent(cover)
        }
      }
      // Cover Flow must work without fetching either art or catalog results.
      if song.artwork?.isFileURL != true { song.artwork = nil }
      return song
    }
  }
  private func scheduleIndex() { Task { await indexLocalFiles() } }
  func indexLocalFiles() async {
    guard loadFailure == nil else { return }
    if indexing {
      needsIndex = true
      return
    }
    indexing = true
    defer { indexing = false }
    repeat {
      needsIndex = false
      rebuildLocalProjection()
      let base = index.deletingLastPathComponent()
      var updates: [String: (URL, DiskMedia)] = [:]
      for song in localSongs {
        guard let file = song.url, let stamp = DiskMedia.stamp(file) else { continue }
        let old = store.media?[song.id]
        if old?.stamp == stamp
          && (old?.cover.map {
            FileManager.default.fileExists(atPath: base.appendingPathComponent($0).path)
          } ?? true)
        {
          continue
        }
        let info = await Task.detached(priority: .utility) {
          await DiskMedia.read(file, stamp: stamp, directory: base, id: song.id)
        }.value
        updates[song.id] = (file, info)
      }
      if !updates.isEmpty {
        var next = store
        if next.media == nil { next.media = [:] }
        for song in store.songs {
          if let (file, info) = updates[song.id], localFile(song) == file,
            DiskMedia.stamp(file) == info.stamp
          {
            next.media?[song.id] = info
          }
        }
        save(next)
      }
    } while needsIndex
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
    guard file.isFileURL,
      (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    else {
      message = "Cached audio is unavailable: \(file.lastPathComponent)"
      return
    }
    var next = store
    if let i = next.songs.firstIndex(where: { $0.id == song.id }) {
      var updated = song
      updated.lyrics = song.lyrics ?? next.songs[i].lyrics
      if updated.url?.isFileURL != false, next.songs[i].url?.isFileURL == false {
        updated.url = next.songs[i].url
      }
      next.songs[i] = updated
    } else {
      remember(song, in: &next)
    }
    let prefix = documents.resolvingSymlinksInPath().path + "/"
    let path = file.resolvingSymlinksInPath().path
    next.removedCacheIDs?.remove(song.id)
    next.externalFiles?[song.id] = nil
    next.supportPaths?[song.id] = nil
    next.media?[song.id] = nil
    if path.hasPrefix(prefix) {
      next.documentsPaths[song.id] = String(path.dropFirst(prefix.count))
    } else {
      next.documentsPaths.removeValue(forKey: song.id)
      let support =
        index.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath().path
        + "/"
      if path.hasPrefix(support + "PlaybackCache/") {
        if next.supportPaths == nil { next.supportPaths = [:] }
        next.supportPaths?[song.id] = String(path.dropFirst(support.count))
      } else {
        if next.externalFiles == nil { next.externalFiles = [:] }
        next.externalFiles?[song.id] = file
      }
    }
    if save(next) {
      scheduleIndex()
      // A cache registration already has network access; save the catalog cover
      // here, never when an offline shelf is opened.
      if let remote = song.artwork, ["http", "https"].contains(remote.scheme?.lowercased()) {
        let base = index.deletingLastPathComponent()
        Task {
          guard let path = await DiskMedia.cacheCover(remote, directory: base),
            localFile(song) == file,
            store.songs.first(where: { $0.id == song.id })?.artwork == remote
          else { return }
          var updated = store
          if updated.cachedArt == nil { updated.cachedArt = [:] }
          updated.cachedArt?[song.id] = path
          save(updated)
        }
      }
    }
  }

  func removeCachedTrack(_ song: Song) {
    guard let original = store.songs.first(where: { $0.id == song.id }), loadFailure == nil else {
      return
    }
    let fm = FileManager.default
    let support = index.deletingLastPathComponent().deletingLastPathComponent()
      .resolvingSymlinksInPath()
    let cache = support.appendingPathComponent("PlaybackCache")
    let docs = documents.resolvingSymlinksInPath()
    let roots =
      (LegacyMigration.audioFolders + ["Imported Music"]).map { docs.appendingPathComponent($0) }
      + [cache]
    var candidates = [localFile(original)].compactMap { $0 }
    #if os(iOS)
      let folder = PlaybackFiles.folder(original)
      if let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
        candidates += entries.filter { $0.deletingPathExtension().lastPathComponent == "audio" }
      }
    #endif
    let shared = Set(
      store.songs.filter { $0.id != song.id }.compactMap {
        localFile($0)?.resolvingSymlinksInPath().path
      })
    do {
      for file in Set(candidates) {
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL
        guard roots.contains(where: { resolved.path.hasPrefix($0.standardizedFileURL.path + "/") }),
          !shared.contains(resolved.path),
          UTType(filenameExtension: file.pathExtension)?.conforms(to: .audio) == true
            || (resolved.path.hasPrefix(cache.path + "/")
              && file.deletingPathExtension().lastPathComponent == "audio"),
          (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        else { continue }
        try fm.removeItem(at: file)
      }
    } catch {
      message = "Could not remove cached audio: \(error.localizedDescription)"
      return
    }
    var next = store
    next.documentsPaths[song.id] = nil
    next.supportPaths?[song.id] = nil
    next.externalFiles?[song.id] = nil
    next.media?[song.id] = nil
    next.cachedArt?[song.id] = nil
    if original.platform == "local"
      || (!next.favoriteIDs.contains(song.id)
        && !next.playlists.contains(where: { $0.songIDs.contains(song.id) }))
    {
      next.songs.removeAll { $0.id == song.id }
      next.favoriteIDs.removeAll { $0 == song.id }
      for i in next.playlists.indices { next.playlists[i].songIDs.removeAll { $0 == song.id } }
    } else if let i = next.songs.firstIndex(where: { $0.id == song.id }),
      next.songs[i].url?.isFileURL == true
    {
      next.songs[i].url = nil
    }
    if next.removedCacheIDs == nil { next.removedCacheIDs = [] }
    next.removedCacheIDs?.insert(song.id)
    save(next)
  }

  private func remember(_ song: Song, in state: inout Store) {
    if !state.songs.contains(where: { $0.id == song.id }) { state.songs.append(song) }
  }

  func createPlaylist(_ name: String) {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    guard
      !playlists.contains(where: { $0.name.localizedCaseInsensitiveCompare(name) == .orderedSame })
    else {
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
      remember(song, in: &next)
      list.songIDs.append(song.id)
    }
    next.playlists.append(list)
    save(next)
  }

  func deletePlaylist(_ id: UUID) {
    var next = store
    next.playlists.removeAll { $0.id == id }
    save(next)
  }

  func add(_ song: Song, to id: UUID) {
    var next = store
    guard let i = next.playlists.firstIndex(where: { $0.id == id }),
      !next.playlists[i].songIDs.contains(song.id)
    else { return }
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
    if let loadFailure {
      message = loadFailure
      return false
    }
    do {
      try FileManager.default.createDirectory(
        at: index.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(next).write(to: index, options: .atomic)
      store = next
      rebuildLocalProjection()
      return true
    } catch {
      message = "Could not save library: \(error.localizedDescription)"
      return false
    }
  }

  // The RN store kept metadata in MMKV but its audio files need no decoder.
  private func recoverLegacyFiles() {
    var next = store
    var known = Set(next.documentsPaths.values)
    let base = documents.resolvingSymlinksInPath()
    for folder in LegacyMigration.audioFolders {
      let root = base.appendingPathComponent(folder)
      guard root.resolvingSymlinksInPath().path == root.path else { continue }
      let fm = FileManager.default
      guard fm.fileExists(atPath: root.path),
        let entries = fm.enumerator(
          at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
      else { continue }
      for case let url as URL in entries {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true,
          UTType(filenameExtension: url.pathExtension)?.conforms(to: .audio) == true
        else { continue }
        let absolute = url.resolvingSymlinksInPath().path
        guard absolute.hasPrefix(root.path + "/") else { continue }
        let path = String(absolute.dropFirst(base.path.count + 1))
        guard known.insert(path).inserted else { continue }
        let song = Song(
          id: "legacy:" + path, title: url.deletingPathExtension().lastPathComponent,
          artist: "Unknown Artist", platform: "local")
        next.songs.append(song)
        next.documentsPaths[song.id] = path
      }
    }
    if next.songs.count != store.songs.count { save(next) }
  }

  func importFiles(_ urls: [URL]) async {
    guard !importing else { return }
    if let loadFailure {
      message = loadFailure
      return
    }
    importing = true
    defer { importing = false }
    let folder = documents.appendingPathComponent("Imported Music")
    var failures: [String] = []
    var imported: [(Song, URL)] = []
    for source in urls {
      do {
        let (file, lyrics) = try await Task.detached(priority: .userInitiated) {
          let granted = source.startAccessingSecurityScopedResource()
          defer { if granted { source.stopAccessingSecurityScopedResource() } }
          return (try Self.copyAudio(source, to: folder), DiskMedia.sidecarLyrics(source))
        }.value
        let song = Song(
          id: "local:" + file.lastPathComponent,
          title: source.deletingPathExtension().lastPathComponent, artist: "Unknown Artist",
          platform: "local", lyrics: lyrics)
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
    if !imported.isEmpty { await indexLocalFiles() }
    if !failures.isEmpty { message = failures.joined(separator: "\n") }
  }

  private nonisolated static func copyAudio(_ source: URL, to folder: URL) throws -> URL {
    let granted = source.startAccessingSecurityScopedResource()
    defer { if granted { source.stopAccessingSecurityScopedResource() } }
    let manager = FileManager.default
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let destination = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(
      source.pathExtension)
    var coordinationError: NSError?
    var result: Result<Void, Error> = .failure(CocoaError(.fileReadUnknown))
    NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) {
      url in
      result = Result {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
        guard values.isRegularFile == true, values.contentType?.conforms(to: .audio) == true else {
          throw CocoaError(.fileReadUnsupportedScheme)
        }
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

// Read the encoded stream ASBD (not AVAudioFile.processingFormat, which always
// describes decoded PCM). A requested streaming tier is never a local badge.
private struct DiskMedia: Codable {
  var stamp: String
  var title: String?, artist: String?, album: String?, albumArtist: String?, cover: String?
  var duration: Double?, track: Int?, disc: Int?, codec: String?, rate: Double?, bits: Int?,
    kbps: Int?
  var lyrics: String?
  var lossless = false
  var badge: String? {
    guard let codec else { return nil }
    if lossless {
      let tier = (rate ?? 0) > 48000 ? "Hi-Res Lossless" : "Lossless"
      let sample = rate.map { String(format: "%g kHz", $0 / 1000) }
      return ([tier, codec] + [bits.map { "\($0)-bit" }, sample].compactMap { $0 }).joined(
        separator: " · ")
    }
    return codec + (kbps.map { " · \($0) kbps" } ?? "")
  }
  static func sidecarLyrics(_ file: URL) -> String? {
    let url = file.deletingPathExtension().appendingPathExtension("lrc")
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= 512_000
    else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
  }
  static func stamp(_ file: URL) -> String? {
    guard
      let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
      let bytes = values.fileSize
    else { return nil }
    let sidecar = file.deletingPathExtension().appendingPathExtension("lrc")
    let modified = try? sidecar.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    return "\(bytes):\(values.contentModificationDate?.timeIntervalSince1970 ?? 0):\(modified?.timeIntervalSince1970 ?? 0)"
  }
  private static func artPath(_ key: String) -> String {
    "Covers/" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
      + ".jpg"
  }
  static func cacheCover(_ remote: URL, directory: URL) async -> String? {
    let relative = artPath(remote.absoluteString)
    if FileManager.default.fileExists(atPath: directory.appendingPathComponent(relative).path) {
      return relative
    }
    var request = URLRequest(
      url: remote, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: 12)
    request.setValue("image/*", forHTTPHeaderField: "Accept")
    guard let (temp, response) = try? await URLSession.shared.download(for: request) else {
      return nil
    }
    defer { try? FileManager.default.removeItem(at: temp) }
    guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
      let size = try? temp.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 12_000_000,
      let data = try? Data(contentsOf: temp)
    else { return nil }
    return saveCover(data, key: remote.absoluteString, directory: directory)
  }
  private static func saveCover(_ data: Data, key: String, directory: URL) -> String? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 760,
          kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    else { return nil }
    let relative = artPath(key)
    let url = directory.appendingPathComponent(relative)
    let encoded = NSMutableData()
    guard
      let out = CGImageDestinationCreateWithData(
        encoded, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(out, image, nil)
    guard CGImageDestinationFinalize(out) else { return nil }
    do {
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try (encoded as Data).write(to: url, options: .atomic)
      return relative
    } catch { return nil }
  }
  static func read(_ file: URL, stamp: String, directory: URL, id: String) async -> Self {
    var m = Self(stamp: stamp)
    m.lyrics = sidecarLyrics(file)
    var handle: AudioFileID?
    if AudioFileOpenURL(file as CFURL, .readPermission, 0, &handle) == noErr, let handle {
      defer { AudioFileClose(handle) }
      func property<T>(_ key: AudioFilePropertyID, _ initial: T) -> T? {
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
          AudioFileGetProperty(handle, key, &size, $0)
        }
        return status == noErr ? result : nil
      }
      if let a = property(kAudioFilePropertyDataFormat, AudioStreamBasicDescription()) {
        m.rate = a.mSampleRate > 0 ? a.mSampleRate : nil
        m.bits = a.mBitsPerChannel > 0 ? Int(a.mBitsPerChannel) : nil
        switch a.mFormatID {
        case kAudioFormatLinearPCM:
          m.codec = "PCM"
          m.lossless = true
        case kAudioFormatAppleLossless:
          m.codec = "ALAC"
          m.lossless = true
          m.bits = [1: 16, 2: 20, 3: 24, 4: 32][Int(a.mFormatFlags)] ?? m.bits
        case kAudioFormatFLAC:
          m.codec = "FLAC"
          m.lossless = true
        case kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2:
          m.codec = "AAC"
        case kAudioFormatMPEGLayer3: m.codec = "MP3"
        default:
          var four = a.mFormatID.bigEndian
          m.codec = withUnsafeBytes(of: &four) {
            String(bytes: $0, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
          }
        }
      }
      if let bitrate = property(kAudioFilePropertyBitRate, UInt32(0)), bitrate > 0 {
        m.kbps = Int((Double(bitrate) / 1000).rounded())
      }
      if let duration = property(kAudioFilePropertyEstimatedDuration, Double(0)),
        duration.isFinite && duration > 0
      {
        m.duration = duration
      }
      var dict: Unmanaged<CFDictionary>?
      var size = UInt32(MemoryLayout<Unmanaged<CFDictionary>?>.size)
      if AudioFileGetProperty(handle, kAudioFilePropertyInfoDictionary, &size, &dict) == noErr,
        let tags = dict?.takeRetainedValue() as? [String: Any]
      {
        func text(_ key: String) -> String? {
          (tags[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        m.title = text("title")
        m.artist = text("artist")
        m.album = text("album")
        m.albumArtist = text("album artist")
        m.track = text("track number")?.split(separator: "/").first.flatMap { Int($0) }
        m.disc = text("disc number")?.split(separator: "/").first.flatMap { Int($0) }
      }
    }
    let asset = AVURLAsset(url: file)
    for item in (try? await asset.load(.commonMetadata)) ?? [] {
      switch item.commonKey {
      case .commonKeyTitle: m.title = (try? await item.load(.stringValue)) ?? m.title
      case .commonKeyArtist: m.artist = (try? await item.load(.stringValue)) ?? m.artist
      case .commonKeyAlbumName: m.album = (try? await item.load(.stringValue)) ?? m.album
      case .commonKeyArtwork:
        if let data = try? await item.load(.dataValue) {
          m.cover = saveCover(data, key: id + stamp, directory: directory)
        }
      default: break
      }
    }
    for item in (try? await asset.load(.metadata)) ?? [] {
      if item.identifier == .id3MetadataBand || item.identifier == .iTunesMetadataAlbumArtist {
        m.albumArtist = (try? await item.load(.stringValue)) ?? m.albumArtist
      }
      if [
        .id3MetadataTrackNumber, .iTunesMetadataTrackNumber, .id3MetadataPartOfASet,
        .iTunesMetadataDiscNumber,
      ].contains(item.identifier) {
        let data = try? await item.load(.dataValue)
        let n =
          (try? await item.load(.stringValue))?.split(separator: "/").first.flatMap { Int($0) }
          ?? data.flatMap { $0.count >= 4 ? Int($0[2]) * 256 + Int($0[3]) : nil }
        if item.identifier == .id3MetadataPartOfASet || item.identifier == .iTunesMetadataDiscNumber
        {
          m.disc = n ?? m.disc
        } else {
          m.track = n ?? m.track
        }
      }
    }
    return m
  }
}

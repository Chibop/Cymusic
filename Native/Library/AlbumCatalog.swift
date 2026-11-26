import Foundation

/// Keep punctuation, diacritics, parentheticals and edition suffixes: these can distinguish releases.
struct AlbumCatalogKey: Hashable, Codable {
  let title: String
  let artist: String

  static func normalized(_ value: String) -> String {
    value.precomposedStringWithCanonicalMapping.split(whereSeparator: \.isWhitespace)
      .joined(separator: " ").lowercased(with: Locale(identifier: "en_US_POSIX"))
  }

  init?(_ title: String?, _ artist: String?) {
    self.title = Self.normalized(title ?? "")
    self.artist = Self.normalized(artist ?? "")
    guard !self.title.isEmpty, !self.artist.isEmpty else { return nil }
  }

  func contains(_ song: Song) -> Bool {
    self == Self(song.album, song.albumArtist ?? song.artist)
  }
}

struct AlbumCatalogRow: Identifiable {
  let song: Song
  let owned: Bool
  let number: Int?
  var id: String { (owned ? "local:" : "catalog:") + song.id }

  private static func matches(_ local: Song, _ remote: Song) -> Bool {
    if local.platform == "apple", local.id == remote.id { return true }
    if let a = local.isrc, let b = remote.isrc, !a.isEmpty, !b.isEmpty {
      return a.caseInsensitiveCompare(b) == .orderedSame
    }
    let norm = AlbumCatalogKey.normalized
    guard !norm(local.title).isEmpty, !norm(local.artist).isEmpty,
          norm(local.title) == norm(remote.title), norm(local.artist) == norm(remote.artist)
    else { return false }
    if let a = local.duration, let b = remote.duration, a > 0, b > 0 { return abs(a - b) <= 3 }
    return true
  }

  /// If even one local recording cannot be placed unambiguously, keep the original local shelf.
  static func merge(local: [Song], catalog: [Song]) -> [Self] {
    let fallback = local.map { Self(song: $0, owned: true, number: nil) }
    guard !local.isEmpty, !catalog.isEmpty else { return fallback }
    var owned = [Int: [Song]]()
    for song in local {
      let exact = catalog.indices.filter { song.platform == "apple" && catalog[$0].id == song.id }
      let indices = exact.isEmpty ? catalog.indices.filter { matches(song, catalog[$0]) } : exact
      guard indices.count == 1, let index = indices.first else { return fallback }
      owned[index, default: []].append(song)
    }
    return catalog.enumerated().flatMap { index, remote -> [Self] in
      if let songs = owned[index] { return songs.map { Self(song: $0, owned: true, number: index + 1) } }
      return [Self(song: remote, owned: false, number: index + 1)]
    }
  }
}

actor AlbumCatalog {
  static let shared = AlbumCatalog()
  private struct Snapshot: Codable {
    let key: AlbumCatalogKey
    let date: Date
    let songs: [Song]
  }
  private let file: URL?
  private var snapshots: [Snapshot]?
  init(file: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
    .appendingPathComponent("AlbumCatalog-v1.json")) { self.file = file }

  func tracks(for key: AlbumCatalogKey,
              lookup: (AlbumCatalogKey) async throws -> [Song] = AlbumCatalog.lookup) async -> [Song] {
    if snapshots == nil {
      snapshots = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode([Snapshot].self, from: $0) } ?? []
    }
    let cached = snapshots?.first { $0.key == key }
    if let cached, Date().timeIntervalSince(cached.date) < (cached.songs.isEmpty ? 900 : 86400) { return cached.songs }
    do {
      let songs = try await lookup(key)
      try Task.checkCancellation()
      snapshots?.removeAll { $0.key == key }
      snapshots?.insert(Snapshot(key: key, date: Date(), songs: songs), at: 0)
      snapshots = Array((snapshots ?? []).prefix(64))
      if let file, let data = try? JSONEncoder().encode(snapshots) { try? data.write(to: file, options: .atomic) }
      return songs
    } catch { return cached?.songs ?? [] }
  }

  static func unique(_ entries: [PoolCatalog.Entry], for key: AlbumCatalogKey) -> PoolCatalog.Entry? {
    let matches = entries.filter { AlbumCatalogKey($0.title, $0.subtitle) == key }
    return Set(matches.map(\.id)).count == 1 ? matches.first : nil
  }

  private static func lookup(_ key: AlbumCatalogKey) async throws -> [Song] {
    let results = try await PoolCatalog.search("\(key.artist) \(key.title)")
    guard let release = unique(results.albums, for: key) else { return [] }
    let songs = try await PoolCatalog.tracks(release).songs
    guard !songs.isEmpty, release.trackCount.map({ $0 == songs.count }) ?? true,
          Set(songs.map(\.id)).count == songs.count,
          songs.allSatisfy({ AlbumCatalogKey($0.album, release.subtitle) == key }) else { return [] }
    return songs.map { track in
      var song = track
      song.albumArtist = release.subtitle
      return song
    }
  }
}

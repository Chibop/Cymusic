import Foundation

struct LyricVersion: Codable, Identifiable {
  let id: Int
  let trackName: String
  let artistName: String
  let albumName: String?
  let duration: Double?
  let syncedLyrics: String?
  let plainLyrics: String?

  var synced: Bool { syncedLyrics?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
  var text: String { synced ? syncedLyrics ?? "" : plainLyrics ?? "" }

  static func search(title: String, artist: String) async throws -> [Self] {
    var parts = URLComponents(string: "https://lrclib.net/api/search")!
    parts.queryItems = [URLQueryItem(name: "track_name", value: title)]
    if !artist.isEmpty { parts.queryItems?.append(URLQueryItem(name: "artist_name", value: artist)) }
    var request = URLRequest(url: parts.url!, timeoutInterval: 15)
    request.setValue("CyMusic (iOS lyric search)", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
      throw URLError(.badServerResponse)
    }
    return try JSONDecoder().decode([Self].self, from: data).filter {
      !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
  }
}

// Ignore periodic samples until the newest seek settles, including after a track change.
struct PlaybackSeekClock {
  private var pending: UUID?
  var acceptsSample: Bool { pending == nil }
  mutating func begin() -> UUID {
    let token = UUID()
    pending = token
    return token
  }
  mutating func finish(_ token: UUID) -> Bool {
    guard pending == token else { return false }
    pending = nil
    return true
  }
}

// Separate from audio storage so audio cache cleanup does not erase a manual choice.
enum LyricSelection {
  static func file(for song: Song) -> URL {
    let audio = PlaybackFiles.folder(song)
    return audio.deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("LyricSelections", isDirectory: true)
      .appendingPathComponent(audio.lastPathComponent).appendingPathExtension("json")
  }

  static func read(_ file: URL) -> LyricVersion? {
    guard let data = try? Data(contentsOf: file) else { return nil }
    return try? JSONDecoder().decode(LyricVersion.self, from: data)
  }

  static func save(_ choice: LyricVersion?, to file: URL) throws {
    if let choice {
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(choice).write(to: file, options: .atomic)
    } else if FileManager.default.fileExists(atPath: file.path) {
      try FileManager.default.removeItem(at: file)
    }
  }
}

import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Each source has its own ID namespace; never use user-provided names as path components.
enum PlaybackFiles {
  static func folder(_ song: Song) -> URL {
    let identity: Data
    if let tier = song.requestedQuality {
      let parts = [song.searchScriptID ?? "", song.platform ?? "", song.id, tier]
      identity = Data(("exact:" + parts.map { "\($0.utf8.count):\($0)" }.joined()).utf8)
    } else {
      identity = Data("\(song.platform ?? "")\u{0}\(song.id)".utf8)
    }
    let key = SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("PlaybackCache", isDirectory: true).appendingPathComponent(
        key, isDirectory: true)
  }
  static func existing(_ song: Song) -> URL? {
    (try? FileManager.default.contentsOfDirectory(at: folder(song), includingPropertiesForKeys: nil))?
      .first { $0.deletingPathExtension().lastPathComponent == "audio" }
  }
  static func save(_ song: Song, source: URL) async throws -> URL {
    if let existing = existing(song) { return existing }
    guard ["http", "https"].contains(source.scheme?.lowercased() ?? ""),
      source.pathExtension.lowercased() != "m3u8"
    else { throw CacheError.unsupported }
    let (temp, response) = try await URLSession.shared.download(from: source)
    defer { try? FileManager.default.removeItem(at: temp) }
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
      http.statusCode != 206
    else { throw URLError(.badServerResponse) }
    let mime = response.mimeType ?? ""
    guard !mime.contains("mpegurl"), !mime.hasPrefix("text/") else { throw CacheError.unsupported }
    let allowed = [
      "mp3", "m4a", "mp4", "aac", "flac", "wav", "aiff", "aif", "caf", "alac", "ogg", "opus",
    ]
    let ext =
      [
        response.url?.pathExtension, source.pathExtension,
        UTType(mimeType: mime)?.preferredFilenameExtension,
      ].compactMap { $0?.lowercased() }.first { allowed.contains($0) } ?? "mp3"
    var folder = folder(song)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try folder.setResourceValues(values)
    let stage = folder.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    try FileManager.default.moveItem(at: temp, to: stage)
    defer { try? FileManager.default.removeItem(at: stage) }
    let asset = AVURLAsset(url: stage)
    guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
      throw CacheError.unsupported
    }
    try Task.checkCancellation()
    if let existing = existing(song) { return existing }
    let final = folder.appendingPathComponent("audio").appendingPathExtension(ext)
    try FileManager.default.moveItem(at: stage, to: final)
    return final
  }
  enum CacheError: ChineseUIError {
    case unsupported
    var errorDescription: String? { "此音频不支持离线缓存。" }
  }
}

struct PlaybackLyric: Identifiable {
  let id: Int
  let time: Double?
  let text: String
  static func parse(_ input: String?) -> [Self] {
    guard let input else { return [] }
    let cues = ShelfLyrics.parse(input)
    if !cues.isEmpty {
      return cues.enumerated().map { Self(id: $0.offset, time: $0.element.time, text: $0.element.text) }
    }
    let rows = input.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
    return rows.filter { !$0.isEmpty && !($0.hasPrefix("[") && $0.hasSuffix("]")) }
      .enumerated().map { Self(id: $0.offset, time: nil, text: $0.element) }
  }

  static func active(at time: Double, in lines: [Self]) -> Int? {
    var low = 0, high = lines.count
    while low < high {
      let mid = low + (high - low) / 2
      if let cue = lines[mid].time, cue <= time { low = mid + 1 } else { high = mid }
    }
    return low > 0 ? lines[low - 1].id : nil
  }
}

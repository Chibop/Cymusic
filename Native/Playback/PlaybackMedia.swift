import AVFoundation
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Each source has its own ID namespace; never use user-provided names as path components.
enum PlaybackFiles {
  static func folder(_ song: Song) -> URL {
    let identity = Data("\(song.platform ?? "")\u{0}\(song.id)".utf8)
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
  enum CacheError: LocalizedError {
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
    let stamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d{1,2}(?:[\.:]\d+)?)\]"#)
    let offsetRegex = try! NSRegularExpression(pattern: #"(?i)\[offset:\s*([+-]?\d+)\s*\]"#)
    let ns = input as NSString
    let offset =
      offsetRegex.firstMatch(in: input, range: NSRange(location: 0, length: ns.length)).flatMap {
        Double(ns.substring(with: $0.range(at: 1)))
      }.map { $0 / 1000 } ?? 0
    var lines: [Self] = []
    for row in input.components(separatedBy: .newlines) {
      let s = row as NSString
      let range = NSRange(location: 0, length: (row as NSString).length)
      let matches = stamp.matches(in: row, range: range)
      let text = stamp.stringByReplacingMatches(in: row, range: range, withTemplate: "")
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty, !text.hasPrefix("[") || !text.hasSuffix("]") else { continue }
      if matches.isEmpty { lines.append(Self(id: lines.count, time: nil, text: text)) }
      for match in matches {
        guard let minutes = Double(s.substring(with: match.range(at: 1))),
          let seconds = Double(
            s.substring(with: match.range(at: 2)).replacingOccurrences(of: ":", with: "."))
        else { continue }
        lines.append(
          Self(id: lines.count, time: max(0, minutes * 60 + seconds - offset), text: text))
      }
    }
    return lines.sorted { ($0.time ?? .infinity, $0.id) < ($1.time ?? .infinity, $1.id) }
  }
}

import Foundation

/// Public Apple catalog artwork; no MusicKit account or playback permission needed.
enum ArtworkCatalog {
  struct Candidate: Identifiable {
    let id: Int64, title: String, detail: String, thumbnail: URL
  }
  struct ResultPage { let candidates: [Candidate], country: String }
  private struct Row: Decodable {
    let collectionId: Int64?, trackId: Int64?, collectionName: String?, trackName: String?
    let artistName: String?, artworkUrl100: URL?, releaseDate: String?
  }
  private struct Page: Decodable { let results: [Row] }
  static func isAppleImage(_ url: URL?) -> Bool {
    guard let url, url.scheme == "https", let host = url.host?.lowercased() else { return false }
    return host.hasSuffix(".mzstatic.com")
  }
  static func search(_ query: String, albumMode: Bool) async throws -> ResultPage {
    var empty: ResultPage?
    var failure: Error = URLError(.cannotLoadFromNetwork)
    for country in ["cn", "hk", "us"] {
      do {
        var parts = URLComponents(string: "https://itunes.apple.com/search")!
        let params = ["term": query, "country": country, "media": "music", "entity": albumMode ? "album" : "song", "limit": "25"]
        parts.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        parts.percentEncodedQuery = parts.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        let (bytes, response) = try await URLSession.shared.data(for: URLRequest(url: parts.url!, timeoutInterval: 12))
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        let rows = try JSONDecoder().decode(Page.self, from: bytes).results
        var seen = Set<Int64>()
        let candidates = rows.compactMap { row -> Candidate? in
          guard let id = albumMode ? row.collectionId : row.trackId,
            let title = albumMode ? row.collectionName : row.trackName,
            let art = row.artworkUrl100, isAppleImage(art), seen.insert(id).inserted else { return nil }
          let detail = [row.artistName, albumMode ? row.releaseDate.map { String($0.prefix(4)) } : row.collectionName].compactMap { $0 }.joined(separator: " · ")
          return Candidate(id: id, title: title, detail: detail, thumbnail: art)
        }
        let result = ResultPage(candidates: candidates, country: country.uppercased())
        if !candidates.isEmpty { return result }
        empty = result
      } catch { try Task.checkCancellation(); failure = error }
    }
    if let empty { return empty }; throw failure
  }

  static func download(_ candidate: Candidate) async throws -> Data {
    let thumbnail = candidate.thumbnail
    guard isAppleImage(thumbnail) else { throw URLError(.unsupportedURL) }
    let larger = thumbnail.deletingLastPathComponent().appendingPathComponent(thumbnail.lastPathComponent.replacingOccurrences(of: "100x100", with: "760x760"))
    var failure: Error = URLError(.cannotDecodeContentData)
    for url in larger == thumbnail ? [thumbnail] : [larger, thumbnail] {
      do {
        let (temp, response) = try await URLSession.shared.download(for: URLRequest(url: url, timeoutInterval: 18))
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), isAppleImage(http.url), http.mimeType?.hasPrefix("image/") == true,
          let n = try temp.resourceValues(forKeys: [.fileSizeKey]).fileSize, (1...12_000_000).contains(n) else { throw URLError(.cannotDecodeContentData) }
        return try Data(contentsOf: temp)
      } catch { try Task.checkCancellation(); failure = error }
    }
    throw failure
  }
}

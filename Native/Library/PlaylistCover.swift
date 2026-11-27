import CryptoKit
import SwiftUI

struct PlaylistCover: View {
  let tracks: [Song]
  @State private var tiles: [UIImage] = []

  var body: some View {
    let urls = tracks.compactMap(\.artwork)
    GeometryReader { bounds in
      ZStack {
        Color(uiColor: .secondarySystemFill)
        if tiles.isEmpty {
          Image(systemName: "music.note.list").font(.system(size: bounds.size.width * 0.36))
            .foregroundStyle(.secondary)
        } else {
          let side = bounds.size.width / 2
          ForEach(tiles.indices, id: \.self) { i in
            Image(uiImage: tiles[i]).resizable().scaledToFill().frame(width: side, height: side)
              .clipped().position(x: (CGFloat(i % 2) + 0.5) * side, y: (CGFloat(i / 2) + 0.5) * side)
          }
        }
      }
    }.clipShape(RoundedRectangle(cornerRadius: 6)).task(id: urls) {
      var seenURLs = Set<URL>(), seenImages = Set<SHA256.Digest>(), images: [UIImage] = []
      for url in urls where seenURLs.insert(url).inserted {
        guard !Task.isCancelled else { return }
        // The index can extract identical album art to different per-track files.
        guard let digest = await PlaylistCoverDigest.shared.digest(url), seenImages.insert(digest).inserted,
          let sample = await CoverFlowArtwork.shared.sample(url) else { continue }
        images.append(sample.image)
        if images.count == 4 { break }
      }
      if !Task.isCancelled { tiles = images }
    }.accessibilityElement(children: .ignore).accessibilityLabel("歌单封面")
  }
}

private actor PlaylistCoverDigest {
  static let shared = PlaylistCoverDigest()
  private var cache: [URL: SHA256.Digest] = [:]
  func digest(_ url: URL) -> SHA256.Digest? {
    if let hit = cache[url] { return hit }
    guard url.isFileURL, let bytes = try? Data(contentsOf: url) else { return nil }
    let hash = SHA256.hash(data: bytes)
    cache[url] = hash
    return hash
  }
}

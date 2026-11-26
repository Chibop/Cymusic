import SwiftUI
import ImageIO

/// Decode once for both the jacket face and the ambient light behind it.
actor CoverFlowArtwork {
  static let shared = CoverFlowArtwork()
  final class Sample: @unchecked Sendable {
    let image: UIImage, color: UIColor
    init(_ image: CGImage, _ color: UIColor) {
      self.image = UIImage(cgImage: image)
      self.color = color
    }
  }
  private let cache: NSCache<NSURL, Sample> = {
    let cache = NSCache<NSURL, Sample>()
    cache.totalCostLimit = 36 * 1024 * 1024
    return cache
  }()
  private var pending: [URL: Task<Sample?, Never>] = [:]

  func sample(_ url: URL) async -> Sample? {
    if let hit = cache.object(forKey: url as NSURL) { return hit }
    if let job = pending[url] { return await job.value }
    let job = Task.detached(priority: .utility) { () -> Sample? in
      let source: CGImageSource?
      if url.isFileURL {
        source = CGImageSourceCreateWithURL(url as CFURL, nil)
      } else {
        guard ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let (file, response) = try? await URLSession.shared.download(from: url) else { return nil }
        defer { try? FileManager.default.removeItem(at: file) }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return nil }
        source = CGImageSourceCreateWithURL(file as CFURL, nil)
        return source.flatMap(Self.decode)
      }
      return source.flatMap(Self.decode)
    }
    pending[url] = job
    let result = await job.value
    pending[url] = nil
    if let result, let image = result.image.cgImage {
      cache.setObject(result, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
    }
    return result
  }

  private static func decode(_ source: CGImageSource) -> Sample? {
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: 800]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
    let rendered = pixels.withUnsafeMutableBytes { buffer -> Bool in
      guard let context = CGContext(data: buffer.baseAddress, width: 32, height: 32, bitsPerComponent: 8,
        bytesPerRow: 128, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
      context.draw(image, in: CGRect(x: 0, y: 0, width: 32, height: 32))
      return true
    }
    guard rendered else { return Sample(image, .darkGray) }
    var votes = [Double](repeating: 0, count: 512)
    var sums = [SIMD3<Double>](repeating: .zero, count: 512)
    for i in stride(from: 0, to: pixels.count, by: 4) where pixels[i + 3] >= 224 {
      let r = Int(pixels[i]), g = Int(pixels[i + 1]), b = Int(pixels[i + 2])
      let key = (r >> 5) * 64 + (g >> 5) * 8 + (b >> 5)
      let chroma = Double(max(r, g, b) - min(r, g, b)) / 255
      let weight = 0.18 + chroma * 2
      votes[key] += weight
      sums[key] += SIMD3(Double(r), Double(g), Double(b)) * weight
    }
    guard let k = votes.indices.max(by: { votes[$0] < votes[$1] }), votes[k] > 0 else { return Sample(image, .darkGray) }
    let rgb = sums[k] / (votes[k] * 255)
    return Sample(image, UIColor(red: rgb.x, green: rgb.y, blue: rgb.z, alpha: 1))
  }

  static func fallbackHue(_ title: String) -> Double {
    let hues = [0.51, 0.02, 0.11, 0.63, 0.76, 0.31]
    return hues[title.utf8.reduce(0) { ($0 + Int($1)) % hues.count }]
  }
}

struct CoverFlowBackdrop: View {
  let art: URL?, title: String
  @State private var sampled: (URL, Color)?
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    let tint = sampled?.0 == art ? sampled?.1 : nil
    ZStack {
      Color.black
      LinearGradient(colors: [.white.opacity(0.10), .white.opacity(0.025)], startPoint: .top, endPoint: .bottom)
      LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.24), .white.opacity(0.07)],
                     startPoint: .topLeading, endPoint: .bottomTrailing)
        .colorMultiply(tint ?? Color(hue: CoverFlowArtwork.fallbackHue(title), saturation: 0.48, brightness: 0.56))
    }.task(id: art) {
      guard let art, let sample = await CoverFlowArtwork.shared.sample(art), !Task.isCancelled else { return }
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) { sampled = (art, Color(sample.color)) }
    }.accessibilityHidden(true)
  }
}

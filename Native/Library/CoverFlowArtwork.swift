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
  private let cache: NSCache<NSString, Sample> = {
    let cache = NSCache<NSString, Sample>()
    cache.totalCostLimit = 36 * 1024 * 1024
    return cache
  }()
  private var pending: [URL: Task<Sample?, Never>] = [:]

  func sample(_ url: URL) async -> Sample? {
    let key = "jacket-v2|\(url.absoluteString)" as NSString
    if let hit = cache.object(forKey: key) { return hit }
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
      cache.setObject(result, forKey: key, cost: image.bytesPerRow * image.height)
    }
    return result
  }

  // Square exports sometimes pad a rectangular jacket. Rectangular sources already
  // retain their aspect ratio and use the ordinary centered square below.
  private static func paddingInset(_ image: CGImage) -> Int {
    let n = image.width
    guard n == image.height, n >= 96,
          let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8,
            bytesPerRow: n * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
          let data = ctx.data else { return 0 }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: n, height: n))
    let rgba = data.assumingMemoryBound(to: UInt8.self)
    guard max(rgba[0], rgba[1], rgba[2]) <= 8, rgba[3] == 255 else { return 0 }

    func band(vertical: Bool, far: Bool) -> Int? {
      var solid = 0
      // Require a flat core, permitting a few JPEG ringing lines at its seam.
      for depth in 0...n / 8 {
        let line = far ? n - 1 - depth : depth
        var deviation = 0, bright = 0
        for p in 0..<n {
          let i = (vertical ? p * n + line : line * n + p) * 4
          guard rgba[i + 3] == 255 else { return nil }
          for channel in 0..<3 {
            deviation = max(deviation, abs(Int(rgba[i + channel]) - Int(rgba[channel])))
          }
          if max(rgba[i], rgba[i + 1], rgba[i + 2]) > 32 { bright += 1 }
        }
        if deviation <= (depth < max(3, n / 100) ? 1 : 5) && solid == depth { solid += 1; continue }
        if bright * 2 >= n {
          return solid >= max(3, n / 100) && solid * 2 >= depth && depth - solid <= 8 ? depth : nil
        }
        if deviation > 20 || depth - solid >= 8 { return nil }
      }
      return nil
    }
    func pair(vertical: Bool) -> Int? {
      guard let a = band(vertical: vertical, far: false),
            let b = band(vertical: vertical, far: true), abs(a - b) <= 1 else { return nil }
      return max(a, b)
    }
    // Four matching edges can be a deliberate picture frame.
    switch (pair(vertical: true), pair(vertical: false)) {
    case (let inset?, nil), (nil, let inset?): return inset
    default: return 0
    }
  }

  private static func decode(_ source: CGImageSource) -> Sample? {
    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: 800]
    // ImageIO preserves aspect ratio and applies EXIF orientation. Clip the resulting
    // pixels without rescaling: the face, its reflection, the SwiftUI jacket and the
    // tint sampler should all see exactly the same centered square.
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
    let side = min(thumbnail.width, thumbnail.height) - 2 * paddingInset(thumbnail)
    let crop = CGRect(x: (thumbnail.width - side) / 2, y: (thumbnail.height - side) / 2,
                      width: side, height: side)
    guard let image = thumbnail.cropping(to: crop) else { return nil }
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
  @State private var paper = Color(white: 0.32)
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      Color(red: 16/255, green: 20/255, blue: 18/255)
      paper.opacity(0.61)
      LinearGradient(stops: [.init(color: .white.opacity(0.07), location: 0),
                             .init(color: .black.opacity(0.039), location: 0.52),
                             .init(color: .black.opacity(1/3), location: 1)],
                     startPoint: UnitPoint(x: 0.46, y: 0), endPoint: UnitPoint(x: 0.54, y: 1))
    }.task(id: SleeveItem(art: art, title: title)) {
      let sample: CoverFlowArtwork.Sample?
      if let art { sample = await CoverFlowArtwork.shared.sample(art) } else { sample = nil }
      guard !Task.isCancelled else { return }
      let color = sample.map { Color($0.color) } ?? Color(hue: CoverFlowArtwork.fallbackHue(title), saturation: 0.48, brightness: 0.56)
      withAnimation(reduceMotion ? nil : .timingCurve(0.25, 0.1, 0.25, 1, duration: 0.58)) { paper = color }
    }.accessibilityHidden(true)
  }
}

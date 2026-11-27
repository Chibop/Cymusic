// From the repository root on an Apple Silicon Mac, with an iOS 18+ simulator booted:
// xcrun swiftc -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" -target arm64-apple-ios18.0-simulator Native/Library/CoverFlow{Artwork,Shelf}.swift scripts/fixtures/CoverFlowPixels.swift -o "$TMPDIR/coverflow-pixels"
// xcrun simctl spawn <simulator-UDID> "$TMPDIR/coverflow-pixels"
import UIKit

@main struct CoverFlowPixels {
  static let format: UIGraphicsImageRendererFormat = {
    let f = UIGraphicsImageRendererFormat(); f.scale = 1; f.opaque = false; return f
  }()
  @MainActor static func checkBands() async throws {
    for (name, expected) in [("sides", 176), ("horizontal", 176), ("frame", 200),
        ("one-sided", 200), ("asymmetric", 200), ("all-black", 200), ("transparent", 200),
        ("textured", 200), ("too-wide", 200), ("too-thin", 200), ("dark-seam", 200)] {
      let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
      let data = UIGraphicsImageRenderer(size: bounds.size, format: format).pngData { c in
        if name != "transparent" { UIColor.black.setFill(); c.fill(bounds) }
        let width: CGFloat = name == "too-wide" ? 48 : name == "too-thin" ? 1 : 12
        var art = bounds.insetBy(dx: width, dy: 0)
        switch name {
        case "horizontal": art = bounds.insetBy(dx: 0, dy: width)
        case "frame": art = art.insetBy(dx: 0, dy: width)
        case "asymmetric": art.size.width -= 5
        case "one-sided": art.size.width += width
        case "all-black": return
        case "textured":
          UIColor(white: 0.04, alpha: 1).setFill()
          for y in stride(from: 0, to: 200, by: 3) { c.fill(CGRect(x: 0, y: y, width: 200, height: 1)) }
        default: break
        }
        (name == "dark-seam" ? UIColor(white: 0.09, alpha: 1) : .orange).setFill(); c.fill(art)
      }
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
      defer { try? FileManager.default.removeItem(at: url) }
      try data.write(to: url)
      let sample = await CoverFlowArtwork.shared.sample(url)
      precondition(sample?.image.cgImage?.width == expected, name)
      let cached = await CoverFlowArtwork.shared.sample(url)
      precondition(cached === sample)
      let after = try Data(contentsOf: url); precondition(after == data)
    }
    print("PASS synthetic band decisions, cached samples and source preservation")
  }

  // Optional directory containing the two 600x600bb Apple exports (US and TW).
  @MainActor static func checkPublicArt(_ directory: URL) async throws {
    for file in ["apple", "apple-tw"] {
      let url = directory.appendingPathComponent(file + ".jpg")
      let stage = SleeveStage(frame: CGRect(x: 0, y: 0, width: 400, height: 700))
      stage.configure(.init(count: 1, focus: 0, reduceMotion: true, step: { _ in }, activate: {},
                            item: { _ in .init(art: url, title: "七里香") }))
      let face = stage.layer.sublayers!.first!.sublayers!.last!
      for _ in 0..<500 where face.contents == nil { try await Task.sleep(nanoseconds: 10_000_000) }
      let sample = await CoverFlowArtwork.shared.sample(url)
      guard let image = sample?.image.cgImage, (face.contents as AnyObject?) === image else { fatalError("face binding") }
      print("\(file) face \(image.width)x\(image.height)")
      precondition(image.width == 542 && image.height == 542, "\(file) produced \(image.width)x\(image.height)")
      let capture = UIGraphicsImageRenderer(size: face.bounds.size, format: format).pngData { c in face.render(in: c.cgContext) }
      try capture.write(to: directory.appendingPathComponent(file + "-face.png"))
    }
  }
  @MainActor static func main() async throws {
    try await checkBands()
    if let dir = CommandLine.arguments.dropFirst().first { try await checkPublicArt(URL(fileURLWithPath: dir)) }
    for (w,h) in [(1800,900),(900,1800)] {
      let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
      defer { try? FileManager.default.removeItem(at: url) }
      let side = min(w,h), x = (w-side)/2, y = (h-side)/2
      let data = UIGraphicsImageRenderer(size: CGSize(width:w,height:h), format: format).pngData { c in
        // Poison margins must disappear. The upper-left and lower-right patches must stay square.
        UIColor.green.setFill(); c.fill(CGRect(x:0,y:0,width:w,height:h))
        UIColor.blue.setFill(); c.fill(CGRect(x:x,y:y,width:side,height:side))
        UIColor.red.setFill(); c.fill(CGRect(x:x+side/8,y:y+side/8,width:side/4,height:side/4))
        UIColor.yellow.setFill(); c.fill(CGRect(x:x+side/2,y:y+side*3/4,width:side/8,height:side/8))
      }
      try data.write(to:url)
      let stage = SleeveStage(frame:CGRect(x:0,y:0,width:400,height:700))
      stage.configure(.init(count:1,focus:0,reduceMotion:true,step:{ _ in },activate:{},item:{ _ in .init(art:url,title:"asymmetric") }))
      let layers = stage.layer.sublayers!.first!.sublayers!
      let front = layers.last!, reflection = layers.first!
      for _ in 0..<500 where front.contents == nil { try await Task.sleep(nanoseconds:10_000_000) }
      guard let sample = await CoverFlowArtwork.shared.sample(url), let image = sample.image.cgImage, front.contents != nil else { fatalError("decode failed") }
      // Render each production face through its parent, retaining the real mask/flip and opacity.
      // Isolate the faces from 3-D projection (CALayer.render doesn't composite CATransformLayer).
      for (face,mirror) in [(front,false),(reflection,true)] {
        let container = CALayer(); container.bounds = face.bounds; container.backgroundColor = UIColor.black.cgColor
        face.removeFromSuperlayer(); container.addSublayer(face)
        face.position = CGPoint(x: container.bounds.midX, y: container.bounds.midY)
        let dim = Int(container.bounds.width)
        var rgba = [UInt8](repeating:0,count:dim*dim*4)
        rgba.withUnsafeMutableBytes { bytes in
          let c = CGContext(data:bytes.baseAddress,width:dim,height:dim,bitsPerComponent:8,bytesPerRow:dim*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
          c.translateBy(x:0,y:CGFloat(dim)); c.scaleBy(x:1,y:-1); container.render(in:c)
        }
        func color(_ x:Int,_ y:Int)->String {
          let i = ((y*dim/100)*dim+x*dim/100)*4, r = Int(rgba[i]), g = Int(rgba[i+1]), b = Int(rgba[i+2])
          if r>2 && g>2 && b*2<min(r,g) { return "yellow" }
          if b>2 && b>max(r,g)*2 { return "blue" }; if r>2 && r>max(b,g)*2 { return "red" }; return "other(\(r),\(g),\(b))"
        }
        let probes = mirror ? [(55,18,"yellow"),(48,18,"blue"),(65,18,"blue"),(55,10,"blue"),(55,28,"blue"),(90,8,"blue")] : [(4,50,"blue"),(95,50,"blue"),(50,4,"blue"),(50,96,"blue"),(15,15,"red"),(35,35,"red"),(10,23,"blue"),(40,23,"blue"),(23,10,"blue"),(23,40,"blue"),(55,81,"yellow")]
        for (px,py,expected) in probes { precondition(color(px,py)==expected,"\(w)x\(h) mirror=\(mirror) @\(px),\(py): expected \(expected), got \(color(px,py))") }
      }
      print("\(w)x\(h): front and reflection pixels pass; sample \(image.width)x\(image.height)")
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      precondition(sample.color.getRed(&r, green: &g, blue: &b, alpha: &a) && b > 0.9 && g < 0.1,
                   "ambient tint included cropped green margins instead of the blue jacket")
      precondition(image.width == image.height, "non-square sample passed to jacket and tint")
    }
  }
}

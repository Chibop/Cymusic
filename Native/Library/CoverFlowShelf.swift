import SwiftUI
import QuartzCore

struct SleeveItem: Equatable {
  let art: URL?, title: String
}

struct CoverFlowShelf: UIViewRepresentable {
  let count: Int, focus: Int, reduceMotion: Bool
  let step: (Int) -> Void, activate: () -> Void
  let item: (Int) -> SleeveItem

  func makeUIView(context: Context) -> SleeveStage { SleeveStage() }
  func updateUIView(_ stage: SleeveStage, context: Context) {
    stage.configure(self)
  }
}

final class SleeveStage: UIView {
  private var shelf: CoverFlowShelf?
  private var cards: [Int: Sleeve] = [:]
  private var lastSize = CGSize.zero
  private var start: CGPoint?

  override init(frame: CGRect) {
    super.init(frame: frame)
    clipsToBounds = true
    var projection = CATransform3DIdentity
    projection.m34 = -1 / 1100
    layer.sublayerTransform = projection
  }
  required init?(coder: NSCoder) { fatalError() }

  func configure(_ next: CoverFlowShelf) {
    let previous = shelf
    shelf = next
    refresh(animated: !next.reduceMotion && previous != nil && previous?.focus != next.focus)
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    if lastSize != bounds.size { refresh(animated: false) }
  }

  private func refresh(animated: Bool) {
    guard let shelf, bounds.width > 0, bounds.height > 0 else { return }
    lastSize = bounds.size
    let side = min(258, max(135, bounds.width * 0.28))
    let depth = min(11, max(7, bounds.width * 0.011))
    let window = max(0, shelf.focus - 5)..<max(0, min(shelf.count, shelf.focus + 6))
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    for index in cards.keys where !window.contains(index) {
      cards.removeValue(forKey: index)?.removeFromSuperlayer()
    }
    for index in window {
      let existing = cards[index]
      let card = existing ?? Sleeve()
      if existing == nil { cards[index] = card; layer.addSublayer(card) }
      card.bind(shelf.item(index))
      card.size(side, depth)
      let n = index - shelf.focus, a = CGFloat(abs(n)), sign = CGFloat(n.signum())
      let x = bounds.midX + (n == 0 ? 0 : sign * side * (0.85 + (a - 1) * 0.46))
      let point = CGPoint(x: x, y: bounds.height * 0.45)
      let z: CGFloat = n == 0 ? 0 : -70 - a * 12
      var pose = CATransform3DMakeTranslation(0, 0, z)
      pose = CATransform3DRotate(pose, -sign * 52 * .pi / 180, 0, 1, 0)
      if shelf.reduceMotion { card.removeAllAnimations() }
      guard card.position != point || !CATransform3DEqualToTransform(card.transform, pose) else { continue }
      if animated, existing != nil {
        let current = card.presentation() ?? card
        for (key, from, to) in [("position", NSValue(cgPoint: current.position), NSValue(cgPoint: point)),
                                ("transform", NSValue(caTransform3D: current.transform), NSValue(caTransform3D: pose))] {
          let animation = CABasicAnimation(keyPath: key)
          animation.fromValue = from; animation.toValue = to
          animation.duration = 0.68
          animation.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.85, 0.2, 1.04)
          card.add(animation, forKey: key)
        }
      } else { card.removeAllAnimations() }
      card.position = point; card.transform = pose
    }
  }

  override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
    start = touches.first?.location(in: self)
  }
  override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { start = nil }
  override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
    defer { start = nil }
    guard let start, let point = touches.first?.location(in: self), let shelf else { return }
    let dx = point.x - start.x
    if abs(dx) > 35 { shelf.step(dx < 0 ? 1 : -1); return }
    guard hypot(dx, point.y - start.y) < 10 else { return }
    for index in cards.keys.sorted(by: { abs($0 - shelf.focus) < abs($1 - shelf.focus) }) {
      guard let face = cards[index]?.front else { continue }
      let presented = face.presentation() ?? face
      let local = presented.convert(point, from: face.presentation() == nil ? layer : layer.presentation())
      if presented.bounds.contains(local) {
        if index == shelf.focus { shelf.activate() } else { shelf.step(index - shelf.focus) }
        return
      }
    }
  }
}

private final class Sleeve: CATransformLayer {
  let front = CALayer()
  private let reflection = CALayer(), fade = CAGradientLayer(), seam = CAGradientLayer()
  private let edges = [CAGradientLayer(), CAGradientLayer()]
  private var item: SleeveItem?, task: Task<Void, Never>?
  override init() {
    super.init()
    reflection.contentsGravity = .resizeAspectFill; reflection.masksToBounds = true
    reflection.opacity = 0.23; reflection.mask = fade
    fade.colors = [UIColor.clear.cgColor, UIColor.black.cgColor]
    fade.locations = [0.52, 1]
    addSublayer(reflection)
    for edge in edges {
      edge.colors = [UIColor.black.withAlphaComponent(0.53), UIColor.white.withAlphaComponent(0.13), UIColor.black.withAlphaComponent(0.33), UIColor.black.withAlphaComponent(0.53)].map(\.cgColor)
      edge.locations = [0, 0.28, 0.65, 1]; edge.startPoint = CGPoint(x: 0, y: 0.5); edge.endPoint = CGPoint(x: 1, y: 0.5)
      addSublayer(edge)
    }
    front.contentsGravity = .resizeAspectFill; front.cornerRadius = 2; front.masksToBounds = true
    front.borderWidth = 1; front.borderColor = UIColor.white.withAlphaComponent(1/3).cgColor
    addSublayer(front)
    seam.colors = [UIColor.black.withAlphaComponent(0.2).cgColor, UIColor.clear.cgColor]
    seam.startPoint = CGPoint(x: 0, y: 0.5); seam.endPoint = CGPoint(x: 1, y: 0.5); front.addSublayer(seam)
  }
  override init(layer: Any) { super.init(layer: layer) }
  required init?(coder: NSCoder) { fatalError() }
  deinit { task?.cancel() }

  func size(_ side: CGFloat, _ depth: CGFloat) {
    guard bounds.width != side || front.zPosition != depth / 2 else { return }
    bounds = CGRect(x: 0, y: 0, width: side, height: side)
    front.frame = bounds; front.zPosition = depth / 2
    seam.frame = CGRect(x: 1, y: 0, width: 4, height: side)
    reflection.bounds = bounds; fade.frame = bounds
    reflection.position = CGPoint(x: side / 2, y: side * 1.53)
    reflection.setAffineTransform(CGAffineTransform(scaleX: 1, y: -1))
    for (i, edge) in edges.enumerated() {
      edge.bounds = CGRect(x: 0, y: 0, width: depth, height: side)
      edge.position = CGPoint(x: i == 0 ? 0 : side, y: side / 2)
      edge.transform = CATransform3DMakeRotation(i == 0 ? -.pi / 2 : .pi / 2, 0, 1, 0)
    }
  }

  func bind(_ next: SleeveItem) {
    guard item != next else { return }
    item = next; task?.cancel()
    let paper = UIColor(hue: CoverFlowArtwork.fallbackHue(next.title), saturation: 0.48, brightness: 0.56, alpha: 1)
    apply(image: nil, paper: paper)
    guard let url = next.art else { return }
    task = Task { @MainActor [weak self] in
      guard let sample = await CoverFlowArtwork.shared.sample(url), !Task.isCancelled else { return }
      CATransaction.begin(); CATransaction.setDisableActions(true)
      self?.apply(image: sample.image.cgImage, paper: sample.color)
      CATransaction.commit()
    }
  }
  private func apply(image: CGImage?, paper: UIColor) {
    for layer in [front, reflection] { layer.contents = image; layer.backgroundColor = paper.cgColor }
    for edge in edges { edge.backgroundColor = paper.cgColor }
  }
}

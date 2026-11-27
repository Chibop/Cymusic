import SwiftUI

struct CoverFlowShelf<Face: View>: View {
  let count: Int, focus: Int, reduceMotion: Bool
  let step: (Int) -> Void, activate: () -> Void
  @ViewBuilder let face: (Int) -> Face

  // Keep an unwrapped position: neither crossing zero nor committing the selection
  // should change the identity or position of a jacket already on screen.
  @State private var position: CGFloat
  @State private var dragOrigin: CGFloat?
  @State private var coast: ShelfCoast?
  @State private var frameTime = Date()
  @State private var fold: CGFloat = 0
  @GestureState private var touching = false

  init(count: Int, focus: Int, reduceMotion: Bool, step: @escaping (Int) -> Void,
       activate: @escaping () -> Void, @ViewBuilder face: @escaping (Int) -> Face) {
    self.count = count; self.focus = focus; self.reduceMotion = reduceMotion
    self.step = step; self.activate = activate; self.face = face
    _position = State(initialValue: CGFloat(focus))
  }

  var body: some View {
    GeometryReader { box in
      let width = box.size.width
      let side = min(width * 0.345, box.size.height * 0.82)
      let pitch = max(1, side * 0.45)
      let resting = CGFloat(focus) + CGFloat(count) * ((position - CGFloat(focus)) / CGFloat(max(1, count))).rounded()
      let pose = coast?.sample(frameTime) ?? (dragOrigin == nil ? resting : position, fold)
      Group {
        let center = Int(pose.0.rounded())
        let visible = min(count, 11)
        let first = Int((pose.0 - CGFloat(visible - 1) / 2).rounded())
        ZStack {
          ForEach(first..<(first + visible), id: \.self) { slot in
            let d = CGFloat(slot) - pose.0
            let a = abs(d), sign: CGFloat = d < 0 ? -1 : 1
            let ramp = min(1, a)
            let moving = abs(pose.1)
            let spread = ramp * (0.88 - 0.44 * moving) + max(0, a - 1) * 0.42
            // The center pinches to a spine while the outer faces remain
            // readable (12.80–13.07 in the reference). Keep face width
            // independent of which way its near edge tilts during reversal.
            let turn = -sign * 55 * ramp
            let yaw = turn + (76 * pose.1 - turn) * (1 - ramp) * moving
            let sweepWidth = 0.13 + 0.45 * ramp
            let apparentWidth = cos(turn * .pi / 180) * (1 - moving) + sweepWidth * moving
            let flatten = apparentWidth / cos(yaw * .pi / 180)
            face(wrapped(slot))
              .frame(width: side, height: side).clipped()
              .overlay(Color.black.opacity(reduceMotion ? 0 : 0.07 * ramp))
              .rotation3DEffect(.degrees(reduceMotion ? 0 : Double(yaw)),
                                axis: (0, 1, 0), perspective: 0.34)
              .scaleEffect(x: reduceMotion ? 1 : flatten, y: 1)
              .offset(x: sign * side * spread)
              .zIndex(-Double(a) + (slot == center ? 0.001 : 0))
          }
        }.frame(width: width, height: box.size.height)
      }
      .clipped().contentShape(Rectangle())
      .onTapGesture(perform: activate)
      .gesture(DragGesture(minimumDistance: 5).updating($touching) { _, active, _ in active = true }
        .onChanged { v in
          guard count > 1, dragOrigin != nil || abs(v.translation.width) > abs(v.translation.height) else { return }
          let current = coast?.sample(v.time) ?? (position, fold)
          let start = dragOrigin ?? current.0
          dragOrigin = start; coast = nil
          position = start - v.translation.width / pitch
          fold = reduceMotion ? 0 : max(-1, min(1, current.1 + (position - current.0) * 1.15))
        }.onEnded { v in
          guard let start = dragOrigin else { return }
          let extra = -(v.predictedEndTranslation.width - v.translation.width) / pitch
          let target = Int((start - v.translation.width / pitch + max(-4, min(4, extra * 0.58))).rounded())
          dragOrigin = nil
          settle(to: target)
          // Selection is committed once (the parent may start playback).
          // A re-grab can start behind the already committed destination.
          let offset = wrapped(target - focus)
          if offset != 0 { step(CGFloat(target) < start ? offset - count : offset) }
        })
    }
    .onChange(of: touching) { active in
      if !active, dragOrigin != nil { dragOrigin = nil; synchronize() }
    }
    .onChange(of: focus) { _ in synchronize() }
    .onChange(of: count) { _ in dragOrigin = nil; coast = nil; fold = 0; position = CGFloat(focus) }
    .task(id: coast?.start) {
      guard let motion = coast else { return }
      while !Task.isCancelled, coast?.start == motion.start {
        frameTime = Date()
        if frameTime.timeIntervalSince(motion.start) >= motion.duration {
          coast = nil
          break
        }
        try? await Task.sleep(nanoseconds: 16_000_000)
      }
    }
  }

  private func wrapped(_ i: Int) -> Int { count > 0 ? (i % count + count) % count : 0 }

  private func synchronize() {
    guard count > 0 else { return }
    let base = Int(position.rounded())
    var offset = wrapped(focus - base)
    if offset > count / 2 { offset -= count }
    if dragOrigin == nil, position == CGFloat(base + offset), fold == 0 { return }
    dragOrigin = nil
    settle(to: base + offset)
  }

  private func settle(to slot: Int) {
    let now = Date(), current = coast?.sample(now) ?? (position, fold)
    coast = reduceMotion ? nil : ShelfCoast(start: now, from: current.0, to: CGFloat(slot), fold: current.1)
    position = CGFloat(slot); fold = 0
  }
}

private struct ShelfCoast {
  let start: Date, from: CGFloat, to: CGFloat, fold: CGFloat
  var duration: Double { 0.34 + min(0.40, Double(abs(to - from)) * 0.11) }

  func sample(_ date: Date) -> (CGFloat, CGFloat) {
    let t = CGFloat(min(1, max(0, date.timeIntervalSince(start) / duration)))
    let remaining = 1 - t
    let open = t * t * (3 - 2 * t)
    return (to + (from - to) * remaining * remaining * remaining, fold * (1 - open))
  }
}
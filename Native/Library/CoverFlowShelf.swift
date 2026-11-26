import SwiftUI

struct CoverFlowShelf<Face: View>: View {
  let count: Int, focus: Int
  let step: (Int) -> Void, activate: () -> Void
  @ViewBuilder let face: (Int) -> Face
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @GestureState private var drag: CGFloat = 0

  var body: some View {
    GeometryReader { box in
      let width = box.size.width
      let size = min(width * 0.58, box.size.height * 0.92)
      let stride = max(1, width * 0.38)
      let progress = reduceMotion || count < 2 ? 0 : min(1, max(-1, -drag / stride))
      let left = min(3, count / 2)
      let right = min(3, count - left - 1)
      let indices = (-left...right).map { (focus + $0 + count) % count }
      ZStack {
        ForEach(indices, id: \.self) { index in
          let slot = (index - focus + count + left) % count - left
          let distance = CGFloat(slot) - progress
          let depth = min(abs(distance), 1)
          let sign: CGFloat = distance < 0 ? -1 : 1
          let offset = sign * width * (depth * 0.347 + max(0, abs(distance) - 1) * 0.135)
          face(index)
            .frame(width: size, height: size)
            .overlay(Color.black.opacity(0.12 * depth))
            .overlay(alignment: distance < 0 ? .leading : .trailing) {
              LinearGradient(colors: [.black.opacity(0.85), .white.opacity(0.58), .black.opacity(0.4)],
                             startPoint: .leading, endPoint: .trailing)
                .frame(width: 1 + 5 * depth)
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.white.opacity(0.22), lineWidth: 0.65))
            .rotation3DEffect(.degrees(reduceMotion ? 0 : Double(sign * depth * 58)),
                              axis: (0, 1, 0), perspective: 0.65)
            .scaleEffect(1 - 0.23 * depth)
            .shadow(color: .black.opacity(0.52), radius: 3, y: 4)
            .offset(x: offset, y: 2 * depth)
            .opacity(min(1, max(0, 3 - abs(distance))))
            .zIndex(-Double(abs(distance)))
        }
      }
      .frame(width: width, height: box.size.height)
      .clipped().contentShape(Rectangle())
      .animation(reduceMotion ? nil : .interactiveSpring(response: 0.34, dampingFraction: 0.86), value: focus)
      .onTapGesture(perform: activate)
      .gesture(DragGesture(minimumDistance: 6).updating($drag) { value, state, transaction in
        transaction.animation = nil
        if abs(value.translation.width) > abs(value.translation.height) { state = value.translation.width }
      }.onEnded { value in
        guard count > 1, abs(value.translation.width) > abs(value.translation.height),
              abs(value.translation.width) > 10 else { return }
        let travel = value.translation.width * 0.65 + value.predictedEndTranslation.width * 0.35
        if abs(travel) > stride * 0.28 { step(travel < 0 ? 1 : -1) }
      })
    }
  }

  init(count: Int, focus: Int, reduceMotion: Bool, step: @escaping (Int) -> Void,
       activate: @escaping () -> Void, @ViewBuilder face: @escaping (Int) -> Face) {
    self.count = count
    self.focus = focus
    self.step = step
    self.activate = activate
    self.face = face
    _drag = GestureState(wrappedValue: 0, resetTransaction: Transaction(animation: reduceMotion ? nil : .interactiveSpring(response: 0.34, dampingFraction: 0.86)))
  }
}

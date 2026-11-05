import SwiftUI

struct PlaybackMarquee: View {
  let text: String
  let active: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var textWidth: CGFloat = 0
  @State private var started = Date()
  private let gap: CGFloat = 48
  private let speed: CGFloat = 28

  var body: some View {
    GeometryReader { geometry in
      let overflowing = textWidth > geometry.size.width + 1
      let scrolling = overflowing && active && !reduceMotion
      TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !scrolling)) { context in
        let distance = textWidth + gap
        let cycle = Double(distance / speed) + 2
        let phase = max(0, context.date.timeIntervalSince(started)).truncatingRemainder(dividingBy: cycle)
        let offset = scrolling ? CGFloat(max(0, phase - 2)) * speed : 0
        HStack(spacing: gap) {
          Text(text).fixedSize(horizontal: true, vertical: false)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
          if overflowing && !reduceMotion {
            Text(text).fixedSize(horizontal: true, vertical: false)
          }
        }
        .fixedSize(horizontal: true, vertical: false)
        .offset(x: -offset)
        .frame(width: geometry.size.width, alignment: .leading)
        .clipped()
        .mask(LinearGradient(stops: [
          .init(color: .white, location: 0),
          .init(color: .white, location: overflowing ? 0.96 : 1),
          .init(color: overflowing ? .clear : .white, location: 1),
        ], startPoint: .leading, endPoint: .trailing))
      }
    }
    .frame(height: 20)
    .font(.system(size: 14))
    .foregroundStyle(.white.opacity(0.7))
    .accessibilityElement(children: .ignore)
    .accessibilityLabel(text)
    .onChange(of: text) { _, _ in started = Date() }
    .onChange(of: active) { _, _ in started = Date() }
  }
}

import SwiftUI
import MTVCore

extension AppModel {
  func movePlayerControl(_ delta: Int) {
    let indices = playerControlIndices
    let index = indices.firstIndex(of: playerButton) ?? 1
    playerButton = indices[min(max(0, index + delta), indices.count - 1)]
  }
  func applyPlaybackRate(_ rate: Float) {
    guard playbackRates.contains(rate), playbackPresented else { return }
    if let engine = mpvEngine {
      Task { [weak self,weak engine] in
        guard let self,let engine else { return }
        do {
          try await engine.setRate(rate)
          guard self.mpvEngine === engine else { return }
          self.playbackRate = rate; self.playbackSpeedVisible = false; self.showPlayerControls()
        } catch { if self.mpvEngine === engine { self.notice = error.localizedDescription } }
      }
    } else if let engine = vlcEngine {
      Task { [weak self, weak engine] in
        guard let self, let engine else { return }
        do {
          try await engine.setRate(rate)
          guard self.vlcEngine === engine else { return }
          self.playbackRate = rate; self.playbackSpeedVisible = false; self.showPlayerControls()
        } catch { if self.vlcEngine === engine { self.playbackSpeedVisible = false; self.notice = error.localizedDescription } }
      }
    } else if let player {
      player.defaultRate = rate
      if !paused { player.rate = rate }
      playbackRate = rate; playbackSpeedVisible = false; showPlayerControls()
    }
  }
}

struct PlaybackSpeedPanel: View {
  @ObservedObject var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  private let focusAnimation = Animation.timingCurve(0.22, 0.8, 0.25, 1, duration: 0.24)

  var body: some View {
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 18) {
        Text(L("播放速度")).font(.system(size: 28, weight: .semibold))
        GeometryReader { geometry in
          let count = model.playbackRates.count
          let step = geometry.size.width / CGFloat(count)
          ZStack(alignment: .leading) {
            Capsule().fill(.primary.opacity(0.15)).frame(height: 2)
              .padding(.horizontal, step / 2).offset(y: 15)
            RoundedRectangle(cornerRadius: 16)
              .fill(.primary.opacity(0.14))
              .frame(width: step - 8, height: 62)
              .offset(x: CGFloat(model.playbackSpeedIndex) * step + 4)
              .animation(reduceMotion ? nil : focusAnimation, value: model.playbackSpeedIndex)
              .allowsHitTesting(false)
            HStack(spacing: 0) {
              ForEach(model.playbackRates.indices, id: \.self) { index in
                let rate = model.playbackRates[index]
                let focused = model.playbackSpeedIndex == index
                let current = model.playbackRate == rate
                Button {
                  model.playbackSpeedIndex = index
                  model.applyPlaybackRate(rate)
                } label: {
                  VStack(spacing: 10) {
                    Text(String(format: "%g×", rate)).font(.system(size: 21, weight: focused ? .semibold : .medium))
                      .monospacedDigit()
                    Circle().fill(.primary.opacity(current || focused ? 1 : 0.35)).frame(width: 6, height: 6)
                  }
                  .foregroundStyle(focused || current ? .primary : .secondary)
                  .frame(width: step, height: 62)
                  .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(current ? .isSelected : [])
                .tvPointerFocus { model.playbackSpeedIndex = index }
              }
            }
          }
          .contentShape(Rectangle())
          .simultaneousGesture(DragGesture(minimumDistance: 12)
            .onChanged { value in
              model.playbackSpeedIndex = min(count - 1, max(0, Int(floor(value.location.x / step))))
            }
            .onEnded { _ in model.applyPlaybackRate(model.playbackRates[model.playbackSpeedIndex]) })
        }
        .frame(height: 62)
      }
      .padding(28).frame(width: 680)
      .tvPopupSurface(radius: 28)
    }
  }
}

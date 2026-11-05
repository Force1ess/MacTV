import MTVCore
import SwiftUI

extension AppModel {
  var systemPlaybackGain: Float {
    guard AudioOutputHardware.needsApplicationVolume() else { return 1 }
    return observedSystemMute ? 0 : (observedSystemVolume ?? 1)
  }
  var effectivePlaybackVolume: Float { playbackVolume * systemPlaybackGain }
  func adjustPlaybackVolume(_ delta: Float) { setPlaybackVolume(min(1, max(0, playbackVolume + delta))) }
  func togglePlaybackMute() { setPlaybackVolume(playbackVolume > 0 ? 0 : lastNonzeroVolume) }
  func setPlaybackVolume(_ volume: Float) {
    guard volume.isFinite, (0...1).contains(volume), playbackPresented else { return }
    if let engine = mpvEngine {
      Task { [weak self,weak engine] in
        guard let self,let engine else { return }
        do {
          try await engine.setVolume(volume * self.systemPlaybackGain)
          guard self.mpvEngine === engine else { return }
          self.playbackVolume = volume
          if volume > 0 { self.lastNonzeroVolume = volume }
        } catch { if self.mpvEngine === engine { self.notice = error.localizedDescription } }
      }
    } else if let engine = vlcEngine {
      Task { [weak self, weak engine] in
        guard let self, let engine else { return }
        do {
          try await engine.setVolume(volume * self.systemPlaybackGain)
          guard self.vlcEngine === engine else { return }
          self.playbackVolume = volume
          if volume > 0 { self.lastNonzeroVolume = volume }
        } catch { if self.vlcEngine === engine { self.notice = error.localizedDescription } }
      }
    } else if let player {
      player.volume = volume * systemPlaybackGain
      playbackVolume = volume
      if volume > 0 { lastNonzeroVolume = volume }
    }
  }
}

struct PlaybackVolumePanel: View {
  @ObservedObject var model: AppModel
  var body: some View {
    ZStack {
      TVPopupBackdrop()
      VStack(spacing: 24) {
        Text(L("播放音量")).font(.system(size: 32, weight: .bold))
        Text("\(Int((model.playbackVolume * 100).rounded()))%")
          .font(.system(size: 54, weight: .medium, design: .rounded)).monospacedDigit()
        ProgressView(value: Double(model.playbackVolume)).tint(.white).frame(width: 400)
        HStack(spacing: 24) {
          ForEach(0..<3) { index in
            TVButton(selected: model.playbackVolumeSelection == index,
              action: { model.playbackVolumeSelection = index; model.handle(.select) },
              hover: { model.playbackVolumeSelection = index }) {
              Label(index == 0 ? "减小" : (index == 1 ? "静音 / 恢复" : "增大"),
                systemImage: index == 0 ? "speaker.minus" : (index == 1 ? "speaker.slash" : "speaker.plus"))
                .font(.system(size: 21)).padding(22)
            }
          }
        }
      }.padding(40).tvPopupSurface(radius: 28)
    }
  }
}

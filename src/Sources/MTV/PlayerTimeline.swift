import Foundation
import MTVCore
import SwiftUI

struct PlayerScrubDraft {
  let ticket: UUID, mediaID: String, source: String
  var position: Double
}

extension AppModel {
  @discardableResult func beginPlayerScrub() -> UUID? {
    guard playbackPresented, !playbackCompleted, playbackInterruption == nil, let item = playingItem,
      let position = PlaybackTimeline.target(playerSeekPreview ?? elapsed, duration: duration) else { return nil }
    let ticket = UUID()
    playerTimelineFocused = true
    playerScrub = PlayerScrubDraft(ticket: ticket, mediaID: item.id, source: item.source, position: position)
    showPlayerControls()
    return ticket
  }
  func updatePlayerScrub(_ position: Double, ticket: UUID? = nil) {
    guard var draft = playerScrub, ticket == nil || ticket == draft.ticket,
      let target = PlaybackTimeline.target(position, duration: duration) else { return }
    draft.position = target; playerScrub = draft
  }
  func movePlayerScrub(_ delta: Double) {
    if playerScrub == nil { beginPlayerScrub() }
    if let current = playerScrub?.position { updatePlayerScrub(current + delta) }
  }
  @discardableResult func commitPlayerScrub(ticket: UUID? = nil) -> Bool {
    guard let draft = playerScrub, ticket == nil || ticket == draft.ticket,
      playingItem?.id == draft.mediaID, playingItem?.source == draft.source,
      let target = PlaybackTimeline.target(draft.position, duration: duration) else { return false }
    playerScrub = nil
    return seekFromTimeline(target)
  }
  func cancelPlayerScrub() {
    playerTimelineFocused = false
    playerScrub = nil; playerSeekPreview = nil; playerSeekTicket = nil
    playerSeekPreviewTask?.cancel(); playerSeekPreviewTask = nil
  }
  func timelineClockChanged() {
    if let preview = playerSeekPreview, abs(elapsed - preview) < 0.75 {
      playerSeekPreview = nil; playerSeekTicket = nil
      playerSeekPreviewTask?.cancel(); playerSeekPreviewTask = nil
    }
  }
}

struct PlayerTimeline: View {
  @ObservedObject var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pointerTicket: UUID?
  private var position: Double { model.playerScrub?.position ?? model.playerSeekPreview ?? model.elapsed }
  var body: some View {
    VStack(spacing: 4) {
      ZStack {
        GeometryReader { geometry in
          let width = max(0, geometry.size.width - 16)
          let fraction = model.duration.isFinite && model.duration > 0
            ? min(1, max(0, position / model.duration)) : 0
          let offset = width * CGFloat(fraction)
          ZStack(alignment: .leading) {
            Capsule().fill(.white.opacity(0.26)).frame(width: width, height: 4)
            Capsule().fill(.white.opacity(0.85)).frame(width: offset, height: 4)
            Circle().fill(.white)
              .frame(width: 10, height: 10)
              .scaleEffect(model.playerTimelineFocused ? 1.55 : 1)
              .shadow(color: .white.opacity(model.playerTimelineFocused ? 0.45 : 0), radius: 5)
              .offset(x: offset - 5)
              .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.playerTimelineFocused)
          }
          .frame(height: geometry.size.height)
          .padding(.horizontal, 8)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        Slider(value: Binding(get: { min(max(0, position), max(1, model.duration)) }, set: { value in
          if pointerTicket == nil { pointerTicket = model.beginPlayerScrub() }
          model.updatePlayerScrub(value, ticket: pointerTicket)
        }), in: 0...max(1, model.duration), onEditingChanged: { editing in
          if editing {
            if pointerTicket == nil { pointerTicket = model.beginPlayerScrub() }
          } else if let ticket = pointerTicket {
            _ = model.commitPlayerScrub(ticket: ticket); pointerTicket = nil
          }
        }).opacity(0.02).disabled(!model.duration.isFinite || model.duration <= 0)
          .accessibilityIdentifier("mtv.playback.timeline")
          .accessibilityLabel(L("播放进度"))
          .accessibilityValue(PlaybackTimeline.timecode(position) + " / " + PlaybackTimeline.timecode(model.duration))
           .onGeometryChange(for: CGRect.self) { geometry in geometry.frame(in: .global) } action: { frame in
            if CommandLine.arguments.contains("--ui-smoke"), frame.width > 100 { model.timelineFrameForTesting = frame }
          }
      }.frame(height: 24)
      HStack {
        Text(PlaybackTimeline.timecode(position))
        Spacer()
        Text(PlaybackTimeline.timecode(model.duration))
      }.font(.system(size: 18, weight: .medium, design: .monospaced)).foregroundStyle(.secondary)
    }.padding(.horizontal, 4).padding(.vertical, 4)
      .onChange(of: model.elapsed) { _, _ in model.timelineClockChanged() }
  }
}

import AVFoundation
import AppKit
import MTVCore

extension UISmoke {
  static func playbackRecoverySmoke(model: AppModel, window: NSWindow, output: URL) async -> [String: Bool] {
    let savedEngine = model.preferredEngine
    defer { model.stopPlayback(); model.preferredEngine = savedEngine; model.notice = nil }
    model.preferredEngine = .system
    let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/MTV/Fixtures/PlaybackFixture.mp4")
    var checks: [String: Bool] = [:]
    func frameReady() async -> Bool {
      for _ in 0..<150 {
        if model.player?.currentItem?.status == .readyToPlay, model.testDecodedFrame() != nil { return true }
        try? await Task.sleep(for: .milliseconds(100))
      }
      return false
    }
    let media = MediaItem(id: "recovery-generated-fixture", title: "生成片源 · 中断恢复", url: fixture.absoluteString)
    model.play(media)
    guard await frameReady(), let first = model.player else { return ["recoveryGeneratedFrameReady": false] }
    checks["recoveryGeneratedFrameReady"] = true
    // Hold the real player's clock without changing the model's requested playback state.
    // This exercises the runtime monitor, not a claim that real Wi-Fi was disconnected.
    first.pause()
    for _ in 0..<160 {
      if model.playbackInterruption != nil { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    checks["recoveryFrozenTimelineShowsWaitingActions"] = model.playbackInterruption != nil && model.player === first && !model.paused
    await settle(); capture(window, to: output.appendingPathComponent("waiting.png"))
    first.play()
    for _ in 0..<40 {
      if model.playbackInterruption == nil { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    checks["recoveryProgressClearsWaitingWithoutReplacingPlayer"] = model.playbackInterruption == nil && model.player === first
    let oldItem = first.currentItem
    NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem)
    await settle()
    checks["recoveryEndFailureNotificationOffersActions"] = model.playbackInterruption != nil
    model.handle(.select)
    let restarted = await frameReady()
    checks["recoveryNotificationRetryCreatesNewPlayer"] = restarted && model.player !== first
    NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: oldItem)
    await settle()
    checks["recoveryRetiredItemNotificationCannotInterruptReplacement"] = model.playbackInterruption == nil
    model.stopPlayback()
    let damaged = output.appendingPathComponent("owned-damaged.mp4")
    do {
      try Data("This is generated invalid media, not a user file".utf8).write(to: damaged)
      model.play(MediaItem(id: "recovery-owned-damaged", title: "生成片源 · 重试", url: damaged.absoluteString))
      for _ in 0..<150 {
        if model.playbackInterruption != nil { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      let failedPlayer = model.player
      checks["recoveryRealDecoderFailureOffersActions"] = failedPlayer?.currentItem?.status == .failed && model.playbackInterruption != nil
      await settle(); capture(window, to: output.appendingPathComponent("failed.png"))
      try FileManager.default.removeItem(at: damaged)
      try FileManager.default.copyItem(at: fixture, to: damaged)
      model.handle(.right)
      checks["recoveryRemoteMovesToReturn"] = model.playbackInterruptionButton == 1
      model.handle(.left); model.handle(.select)
      let recovered = await frameReady()
      checks["recoveryRemoteRetryReopensOriginalReference"] = recovered && model.player !== failedPlayer && model.playbackInterruption == nil
      NotificationCenter.default.post(name: .AVPlayerItemFailedToPlayToEndTime, object: model.player?.currentItem)
      await settle()
      model.handle(.right); model.handle(.select)
      checks["recoveryRemoteReturnClearsInterruption"] = !model.playbackPresented && model.playbackInterruption == nil
      try FileManager.default.removeItem(at: damaged)
    } catch { checks["recoveryOwnedFixtureSetup"] = false }
    return checks
  }
}

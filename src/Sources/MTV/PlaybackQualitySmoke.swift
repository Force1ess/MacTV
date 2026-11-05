import AppKit
import MTVCore

extension UISmoke {
  @MainActor static func playbackQualitySmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<300 { if condition() { return }; try? await Task.sleep(for: .milliseconds(40)) }
    }
    let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/IndependentLongGOP45-v1.mp4")
    let item = MediaItem(id: "owned-quality", title: "清晰度切换验证", source: "mtv.bilibili", reference: "BVowned")
    model.preferredEngine = .system; model.playbackVolume = 0
    model.beginPlayback(url: fixture, item: item, fromBeginning: true)
    await wait { model.playbackPresented && model.duration > 0 && model.elapsed > 0.2 }
    do {
      let descriptor = try JSONDecoder().decode(PlaybackDescriptor.self, from: Data(#"{"url":"https://example.invalid/owned.mp4","quality":112,"qualityTitle":"1080P 高码率","height":1080,"bandwidth":12000000,"qualities":[{"id":120,"title":"4K","available":false,"reason":"平台未返回此档位"},{"id":112,"title":"1080P 高码率","available":true},{"id":80,"title":"1080P","available":true}],"note":"自建离线描述，不请求平台"}"#.utf8))
      model.receiveBilibiliQuality(descriptor)
      checks["actualQualityMetadataAndRemoteControlAvailable"] = model.bilibiliActualQuality == 112 && model.bilibiliActualQualityTitle == "1080P 高码率" && model.playerControlIndices.contains(11)
      model.playerCommand(11); model.handle(.down); model.handle(.select)
      checks["unavailablePlatformQualityCannotStartRequest"] = model.playbackQualityVisible && model.bilibiliQualityPreference == "auto" && model.pendingQualityResume == nil
      await settle(); capture(window, to: output.appendingPathComponent("quality-menu.png"))
      model.handle(.back)
      checks["qualityMenuBackKeepsVideoAndReturnsToHUD"] = !model.playbackQualityVisible && model.playbackPresented && model.playerControlsVisible
      for position in [24.0, 2.5, 44.0] {
        model.pendingQualityResume = PlaybackQualityResume(itemID: item.id, position: position, paused: true)
        model.playbackRate = 1.5
        model.beginPlayback(url: fixture, item: item)
        await wait { model.player?.currentItem?.status == .readyToPlay && abs((model.player?.currentTime().seconds ?? -100) - position) < 0.2 }
        let actual = model.player?.currentTime().seconds ?? -100
        checks["qualityRestartPreservesNativePosition-\(position)"] = abs(actual - position) < 0.2 && abs(model.elapsed - actual) < 0.2 && model.playbackInterruption == nil
        checks["qualityRestartKeepsPauseAndSpeed-\(position)"] = model.paused && model.player?.rate == 0 && model.playbackRate == 1.5
      }
      model.pendingQualityResume = PlaybackQualityResume(itemID: item.id, position: 24, paused: true)
      model.stopPlayback(); checks["explicitStopCancelsPendingQualityIntent"] = model.pendingQualityResume == nil
      model.beginPlayback(url: fixture, item: MediaItem(id: "another-owned-video", title: "另一视频", url: fixture.absoluteString), fromBeginning: true)
      await wait { model.playingItem?.id == "another-owned-video" && model.player?.currentItem?.status == .readyToPlay && (model.player?.currentTime().seconds ?? 0) > 0.2 }
      checks["unrelatedVideoDoesNotInheritQualityPosition"] = model.elapsed < 4 && !model.paused && !model.hasBilibiliQualityMenu
    } catch { checks["qualityFixtureDecoded"] = false }
    model.stopPlayback(); await model.waitForPlaybackShutdown()
    return checks
  }
}

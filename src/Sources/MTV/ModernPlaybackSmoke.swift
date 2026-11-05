import AppKit
import MTVCore

extension UISmoke {
  static func modernPlaybackSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    checks.merge(backNavigationSmoke(model: model)) { _, latest in latest }
    checks.merge(await aboutMacTVSmoke(model: model, output: output)) { _, latest in latest }
    let old = model.preferredEngine
    defer { model.stopPlayback(); model.preferredEngine = old; model.playbackRate = 1; model.notice = nil; model.navigate(.home) }
    let fixtures = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/codec-matrix-v1")
    checks["releaseDoesNotBundleLegacyVLC"] = !VLCPlaybackEngine.isAvailable
      && !FileManager.default.fileExists(atPath: Bundle.main.resourceURL!.appendingPathComponent("VLCEngine").path)
    checks["userDoesNotChoosePlaybackEngine"] = !TVSetting.groups.flatMap { $0 }.contains(.engine)
    checks["playbackBarOmitsTechnicalAndDuplicateControls"] = [6, 9, 10].allSatisfy { !model.playerControlIndices.contains($0) }
    checks.merge(await automaticPlaybackSmoke(model: model, root: fixtures, output: output)) { _, latest in latest }
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<300 { if condition() { return }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    for subtitles in [false, true] {
      let name = subtitles ? "subtitles" : "audio"
      model.preferredEngine = .mpv; model.notice = nil
      let file = fixtures.appendingPathComponent(subtitles ? "h264-two-subtitles.mp4" : "h264-two-audio.mp4")
      model.beginPlayback(url: file, item: MediaItem(id: "modern-owned-" + name, title: "播放验证", url: file.absoluteString), fromBeginning: true)
      await wait { model.notice != nil || (model.mpvEngine?.latest?.frames ?? 0) > 3 }
      guard let engine = model.mpvEngine else { checks[name + "-actualMPVStarted"] = false; continue }
      checks[name + "-ordinaryUITestRemainsMuted"] = await engine.diagnostic("mute") == "yes"
      checks[name + "-actualGPUPlayback"] = engine.latest?.vo == "gpu-next" && (engine.latest?.frames ?? 0) > 0 && model.notice == nil
      model.openPlaybackTracks(subtitles ? .subtitles : .audio)
      await wait { !model.playbackTracks.loading }
      let menu = model.playbackTracks
      let tracks = menu.options.compactMap(\.trackID).filter { $0 >= 0 }
      checks[name + "-bothEmbeddedTracksAvailable"] = tracks.count == 2
      if let track = tracks.last {
        let applied = await engine.selectTrack(subtitles: subtitles, id: track)
        let actual = await engine.diagnostic(subtitles ? "sid" : "aid")
        checks[name + "-nativeTrackSelectionConfirmed"] = applied && actual == String(track)
      } else { checks[name + "-nativeTrackSelectionConfirmed"] = false }
      if subtitles {
        checks["subtitlesCanBeDisabledInNativePlayer"] = await engine.selectTrack(subtitles: true, id: -1)
        checks["subtitlesActuallyDisabled"] = await engine.diagnostic("sid") == "no"
      } else {
        let codec = await engine.diagnostic("audio-codec-name")
        let rate = Double(await engine.diagnostic("audio-params/samplerate")) ?? 0
        checks["audioDecoderHasActualFormat"] = !codec.isEmpty && rate > 0
      }
      model.handle(.back)
      model.playerCommand(1); await wait { engine.latest?.paused == true }
      let target = min(3, max(0.5, (engine.latest?.duration ?? 0) / 3))
      checks[name + "-timelineSeekAccepted"] = model.seekFromTimeline(target)
      for _ in 0..<100 {
        if abs((Double(await engine.diagnostic("time-pos")) ?? -100) - target) < 0.25 { break }
        try? await Task.sleep(for: .milliseconds(30))
      }
      let position = Double(await engine.diagnostic("time-pos")) ?? -100
      model.applyPlaybackRate(1.5)
      try? await Task.sleep(for: .milliseconds(350))
      let after = Double(await engine.diagnostic("time-pos")) ?? -100
      let speed = Double(await engine.diagnostic("speed")) ?? 0
      checks[name + "-seekAndSpeedKeepPauseAndPosition"] = abs(position - target) < 0.25
        && abs(after - position) < 0.1 && engine.latest?.paused == true
        && abs(speed - 1.5) < 0.001
      do { try await engine.screenshot(output.appendingPathComponent("mpv-" + name + ".png")) }
      catch { checks[name + "-nativeScreenshot"] = false }
      model.showPlayerControls(); model.handle(.back)
      checks[name + "-firstBackHidesControls"] = model.playbackPresented && !model.playerControlsVisible
      model.handle(.back); await engine.waitUntilStopped()
      checks[name + "-secondBackClosesPlayback"] = !model.playbackPresented && model.mpvEngine == nil
    }
    checks.merge(await subtitleHandoffSmoke(model: model, output: output)) { _, latest in latest }
    return checks
  }
}

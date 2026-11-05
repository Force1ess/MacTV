import AppKit
import Foundation
import MTVCore

extension UISmoke {
  static func mpvPlaybackSmoke(model: AppModel,output: URL,window: NSWindow) async -> [String:Bool] {
    guard let option = CommandLine.arguments.firstIndex(of:"--test-media"),option + 1 < CommandLine.arguments.count else { return ["mpvRequiresExplicitLocalTestMedia":false] }
    let file = URL(fileURLWithPath:CommandLine.arguments[option + 1]), oldEngine = model.preferredEngine
    var checks: [String:Bool] = [:], evidence: [String:Any] = [:]
    defer { model.stopPlayback(); model.preferredEngine = oldEngine; model.playbackRate = 1; model.playbackVolume = 1; model.notice = nil; model.navigate(.home) }
    func wait(_ condition: ()->Bool) async {
      for _ in 0..<300 { if condition() { return }; try? await Task.sleep(for:.milliseconds(50)) }
    }
    do {
      let prefix = try await Task.detached {
        let handle = try FileHandle(forReadingFrom:file); defer { try? handle.close() }
        return try handle.read(upToCount:262144) ?? Data()
      }.value
      checks["mpvActualMediaIdentifiedAsDolbyProfile5"] = ContainerInspection.dolbyVisionProfile(prefix) == 5
      model.preferredEngine = .automatic
      let item = MediaItem(id:"mpv-dolby-owned-media-test",title:"杜比影片播放验证",overview:"使用原文件，不转换或改写媒体。",url:file.absoluteString)
      model.play(item,fromBeginning:true)
      await wait { model.notice != nil || (model.mpvEngine?.latest?.elapsed ?? 0) > 2 }
      guard let engine = model.mpvEngine else { throw MTVError.message(model.notice ?? "自动策略未进入MPV") }
      checks["mpvAutomaticPolicyUsesActualGPUOutput"] = engine.latest?.vo == "gpu-next" && engine.latest?.matrix == "dolbyvision" && (engine.latest?.frames ?? 0) > 0
      checks["mpvSwiftUIControlsAreInNativePlaybackWindow"] = engine.windowForTesting()?.contentView?.subviews.contains { String(describing:type(of:$0)).contains("MPVTransparentHost") } == true
      let interpolation = await engine.diagnostic("interpolation"), sync = await engine.diagnostic("video-sync")
      checks["mpvUsesStandardFrameTimingWithoutMotionInterpolation"] = interpolation == "no" && sync == "audio"
      try await engine.screenshot(output.appendingPathComponent("dolby-early-rendered.png"))
      if let playerWindow = engine.windowForTesting() { capture(playerWindow,to:output.appendingPathComponent("swiftui-controls.png")) }
      model.playerCommand(1); await wait { engine.latest?.paused == true }
      let pausedAt = Double(await engine.diagnostic("time-pos")) ?? 0
      try? await Task.sleep(for:.milliseconds(500))
      let stillAt = Double(await engine.diagnostic("time-pos")) ?? 0
      checks["mpvRemotePauseStopsActualClock"] = await engine.diagnostic("pause") == "yes" && abs(pausedAt - stillAt) < 0.1
      model.applyPlaybackRate(1.5); await settle()
      let nativeRate = Double(await engine.diagnostic("speed")) ?? 0
      let nativePaused = await engine.diagnostic("pause")
      checks["mpvRateChangesWhileRemainingPaused"] = abs(nativeRate - 1.5) < 0.001 && nativePaused == "yes"
      model.playerCommand(1); await wait { !model.paused }
      model.playerCommand(2); await wait { model.elapsed > pausedAt + 8 }
      checks["mpvRemoteForwardSeeksActualTimeline"] = model.elapsed > pausedAt + 8
      model.setPlaybackVolume(0.4); await settle()
      checks["mpvVolumeUsesNativePlayerProperty"] = abs((Double(await engine.diagnostic("volume")) ?? -1) - 40) < 0.1
      model.openPlaybackTracks(.audio); await wait { !model.playbackTracks.loading }
      let audio = model.playbackTracks.options.compactMap(\.trackID)
      checks["mpvOriginalAudioTracksRemainSelectable"] = audio.count >= 2
      if let second = audio.last {
        checks["mpvNativeAudioSelectionConfirmed"] = await engine.selectTrack(subtitles:false,id:second)
      }
      model.handle(.back)
      model.openPlaybackTracks(.subtitles); await wait { !model.playbackTracks.loading }
      let subtitles = model.playbackTracks.options.compactMap(\.trackID)
      checks["mpvOriginalSubtitlesAndOffOptionPresent"] = subtitles.count > 2 && subtitles.contains(-1)
      if let first = subtitles.first(where:{$0 > 0}) {
        checks["mpvNativeSubtitleSelectionConfirmed"] = await engine.selectTrack(subtitles:true,id:first)
        checks["mpvNativeSubtitleOffConfirmed"] = await engine.selectTrack(subtitles:true,id:-1)
      }
      model.handle(.back)
      engine.seek(62); await wait { abs(model.elapsed - 62) < 1 }
      engine.pause(true); await wait { model.paused }
      try await engine.screenshot(output.appendingPathComponent("dolby-62s-rendered.png"))
      for key in ["mpv-version","current-vo","video-params/colormatrix","video-out-params/colormatrix","hwdec-current","audio-codec-name","audio-out-params","speed","volume","mute"] { evidence[key] = await engine.diagnostic(key) }
      model.showPlayerControls(); model.handle(.back)
      checks["mpvFirstBackHidesControlsWithoutClosingPlayer"] = model.mpvEngine === engine && !model.playerControlsVisible
      model.handle(.back); await engine.waitUntilStopped()
      checks["mpvRemoteBackClosesPlayerAndRestoresLibrary"] = !model.playbackPresented && window.isVisible
      let saved = model.resumeStore.record(for:item.id,source:item.source)?.resumablePosition ?? 0
      checks["mpvProgressSavedUnderSameMediaIdentity"] = abs(saved - 62) < 2
      model.play(item); await wait { model.notice != nil || (model.mpvEngine?.latest?.elapsed ?? 0) > 60 }
      if let replay = model.mpvEngine {
        checks["mpvRestartRestoresSavedPosition"] = abs((replay.latest?.elapsed ?? 0) - saved) < 2
        model.stopPlayback(); await replay.waitUntilStopped()
      } else { checks["mpvRestartRestoresSavedPosition"] = false }
    } catch { checks["mpvPlaybackFlowCompleted"] = false; evidence["error"] = error.localizedDescription }
    evidence["physicalHDRorDolbyTVOutputVerified"] = false
    evidence["physicalAudioAudibilityVerified"] = false
    if let data = try? JSONSerialization.data(withJSONObject:evidence,options:[.prettyPrinted,.sortedKeys]) {
      try? data.write(to:output.appendingPathComponent("mpv-playback-observations.json"))
    }
    return checks
  }
}

import AVFoundation
import AppKit
import MTVCore

extension UISmoke {
  static func bilibiliPlaybackOnly(model: AppModel, output: URL) async -> (checks: [String: Bool], diagnostics: [String: Any]) {
    var checks: [String: Bool] = ["liveServicesExplicitlyRequested": CommandLine.arguments.contains("--live-services")]
    var diagnostics: [String: Any] = ["realAccountAuthorizationVerified": false, "physicalAudioOutputVerified": false]
    guard checks["liveServicesExplicitlyRequested"] == true else { return (checks, diagnostics) }
    let arguments = CommandLine.arguments
    var indexed = arguments.contains("--test-indexed-hls")
    let recent = arguments.contains("--test-last-bilibili") ? try? PlaybackResumeStore().recent().first(where: { $0.context.sourceID == "mtv.bilibili" }) : nil
    let requested = arguments.firstIndex(of: "--test-bilibili-reference").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? recent?.context.reference
    if let requested, requested.range(of: #"^BV[0-9A-Za-z]{10}(:[1-9][0-9]{0,15})?$"#, options: .regularExpression) == nil {
      checks["validBilibiliReference"] = false; return (checks, diagnostics)
    }
    guard let plugin = model.plugins.first(where: { $0.id == "mtv.bilibili" }) else {
      checks["bilibiliPluginPresent"] = false; return (checks, diagnostics)
    }
    defer { model.stopPlayback(); model.notice = nil; model.navigate(.home) }
    model.openModule(plugin)
    for _ in 0..<280 {
      if !model.loading { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    let candidate = requested.flatMap { ref in model.online.first { $0.reference == ref } } ?? model.online.first
    guard let reference = requested ?? candidate?.reference else {
      checks["bilibiliTargetAvailable"] = false; diagnostics["error"] = model.notice ?? "没有可选视频"; return (checks, diagnostics)
    }
    let target = candidate?.reference == reference ? candidate! : MediaItem(id: reference,
      title: recent?.context.title ?? "Bilibili · " + reference, source: plugin.id, reference: reference)
    diagnostics["reference"] = reference; diagnostics["title"] = target.title
    model.stopPlayback(); model.notice = nil; model.play(target)
    var decoded = false
    var probe: PlaybackAudioProbe?
    var audioChecked = false
    for _ in 0..<450 {
      if model.notice != nil || model.player?.currentItem?.status == .failed { break }
      if let item = model.player?.currentItem, item.status == .readyToPlay {
        indexed = indexed || model.smokePlaybackResolution["adapter"] as? String == "indexed-hls"
        if !audioChecked {
          audioChecked = true
          if !indexed, let track = try? await item.asset.loadTracks(withMediaType: .audio).first,
            let created = try? PlaybackAudioProbe() { created.attach(to: item, track: track); probe = created }
        }
        if model.playbackTitle == target.title, model.elapsed > 2, let frame = model.testDecodedFrame() {
          decoded = true; diagnostics["decodedWidth"] = frame.width; diagnostics["decodedHeight"] = frame.height
          if indexed || (probe?.result.frames ?? 0) > 0 { break }
        }
      }
      try? await Task.sleep(for: .milliseconds(100))
    }
    checks["bilibiliTargetNativeFrame"] = decoded && model.player?.currentItem?.status == .readyToPlay
      && model.playbackTitle == target.title
    checks["bilibiliTargetTimeline"] = model.player != nil && model.playbackTitle == target.title && model.elapsed > 2
    if indexed, let item = model.player?.currentItem {
      let group = try? await item.asset.loadMediaSelectionGroup(for: .audible)
      checks["indexedHLSNativeAudioSelected"] = group.flatMap { item.currentMediaSelection.selectedMediaOption(in: $0) } != nil
      let beforeProbe = await model.smokeRemoteStatistics()
      checks["indexedHLSFetchedAudioBeyondInitialization"] = (beforeProbe["audioRequests"] ?? 0) > 1 && (beforeProbe["audioBytes"] ?? 0) > 262_144
      do {
        let sample = try await model.smokeIndexedAudioDecode()
        checks["indexedHLSIndependentAACSampleDecodedPCM"] = (sample["frames"] ?? 0) > 0
        diagnostics["independentAACSample"] = sample
      } catch { checks["indexedHLSIndependentAACSampleDecodedPCM"] = false; diagnostics["aacSampleError"] = error.localizedDescription }
      diagnostics["playerAudioTapApplicable"] = false
      diagnostics["playerAudioPCMVerified"] = false
    } else { checks["bilibiliTargetAudioPCM"] = (probe?.result.frames ?? 0) > 0 }
    if let option = arguments.firstIndex(of: "--test-hold-seconds"), option + 1 < arguments.count,
      let seconds = Int(arguments[option + 1]), (10...300).contains(seconds) {
      let held = await PlaybackSustainProbe.run(model: model, seconds: seconds, phase: "beforeSeek", output: output)
      checks.merge(held.checks) { _, new in new }; diagnostics["beforeSeek"] = held.diagnostics
    }
    if let position = arguments.firstIndex(of: "--test-seek-seconds"), position + 1 < arguments.count,
      let targetTime = Double(arguments[position + 1]), targetTime.isFinite, targetTime >= 10, targetTime < 7200,
      let player = model.player, let item = player.currentItem {
      let timeout = Task { do { try await Task.sleep(for: .seconds(10)) } catch { return }; item.cancelPendingSeeks() }
      let started = Date()
      let complete = await player.seek(to: CMTime(seconds: targetTime, preferredTimescale: 600), toleranceBefore: CMTime(seconds: 0.1, preferredTimescale: 600), toleranceAfter: CMTime(seconds: 0.1, preferredTimescale: 600))
      timeout.cancel()
      var seekFrame = false
      for _ in 0..<100 {
        if abs(player.currentTime().seconds - targetTime) < 2, let frame = model.testDecodedFrame() {
          seekFrame = true; diagnostics["seekFrameWidth"] = frame.width; diagnostics["seekFrameHeight"] = frame.height; break
        }
        try? await Task.sleep(for: .milliseconds(30))
      }
      checks["indexedHLSFarSeekDecodedWithoutWaitingForTimeline"] = complete && seekFrame && Date().timeIntervalSince(started) < 12
      diagnostics["seekTarget"] = targetTime; diagnostics["seekObserved"] = player.currentTime().seconds
      diagnostics["seekWallSeconds"] = Date().timeIntervalSince(started)
    }
    if let option = arguments.firstIndex(of: "--test-after-seek-hold-seconds"), option + 1 < arguments.count,
      let seconds = Int(arguments[option + 1]), (10...120).contains(seconds) {
      let held = await PlaybackSustainProbe.run(model: model, seconds: seconds, phase: "afterSeek", output: output)
      checks.merge(held.checks) { _, new in new }; diagnostics["afterSeek"] = held.diagnostics
    }
    await model.waitForSmokePreparationTrace()
    if arguments.contains("--test-quality-switch"), decoded, let initialPlayer = model.player {
      let initialCode = model.bilibiliActualQuality ?? 0
      diagnostics["initialQuality"] = model.smokePlaybackResolution
      if let lower = model.bilibiliQualityOptions.first(where: { $0.available && $0.id < initialCode }),
        let lowerIndex = model.bilibiliQualityOptions.firstIndex(where: { $0.id == lower.id }) {
        model.playerCommand(1)
        let accepted = model.seekFromTimeline(12)
        for _ in 0..<240 {
          if abs((model.player?.currentTime().seconds ?? -100) - 12) < 0.3 { break }
          try? await Task.sleep(for: .milliseconds(50))
        }
        diagnostics["beforeSwitch"] = ["seekAccepted": accepted, "nativePosition": initialPlayer.currentTime().seconds,
          "displayPosition": model.elapsed, "modelDuration": model.duration, "nativeDuration": initialPlayer.currentItem?.duration.seconds ?? -1]
        checks["liveSwitchSetupReachedRequestedPosition"] = accepted && abs(initialPlayer.currentTime().seconds - 12) < 0.3
        model.applyPlaybackRate(1.5)
        model.presentPlaybackQuality(); model.qualitySelection = lowerIndex + 1; model.handle(.select)
        for _ in 0..<500 {
          if model.notice != nil { break }
          if let player = model.player, player !== initialPlayer, player.currentItem?.status == .readyToPlay,
            model.bilibiliActualQuality == lower.id, abs(player.currentTime().seconds - 12) < 0.3 { break }
          try? await Task.sleep(for: .milliseconds(60))
        }
        checks["liveQualitySwitchUsesRequestedLowerStream"] = model.bilibiliActualQuality == lower.id && model.player != nil && model.player !== initialPlayer
        checks["liveQualitySwitchKeepsPositionPauseAndRate"] = abs((model.player?.currentTime().seconds ?? -100) - 12) < 0.3
          && model.paused && model.player?.rate == 0 && model.playbackRate == 1.5 && model.notice == nil
        diagnostics["lowerQuality"] = model.smokePlaybackResolution
        diagnostics["lowerState"] = ["nativePosition": model.player?.currentTime().seconds ?? -100, "paused": model.paused, "rate": model.playbackRate, "nativeRate": model.player?.rate ?? -1]
        let lowerPlayer = model.player
        model.presentPlaybackQuality(); model.qualitySelection = 0; model.handle(.select)
        for _ in 0..<500 {
          if model.notice != nil { break }
          if let player = model.player, player !== lowerPlayer, player.currentItem?.status == .readyToPlay,
            model.bilibiliActualQuality == initialCode, abs(player.currentTime().seconds - 12) < 0.3 { break }
          try? await Task.sleep(for: .milliseconds(60))
        }
        checks["liveAutoRestoresHighestAvailableStream"] = model.bilibiliActualQuality == initialCode && model.player != nil && model.player !== lowerPlayer
        checks["liveAutoKeepsPositionPauseAndRate"] = abs((model.player?.currentTime().seconds ?? -100) - 12) < 0.3
          && model.paused && model.player?.rate == 0 && model.playbackRate == 1.5 && model.notice == nil
        diagnostics["restoredQuality"] = model.smokePlaybackResolution
        diagnostics["restoredState"] = ["nativePosition": model.player?.currentTime().seconds ?? -100, "paused": model.paused, "rate": model.playbackRate, "nativeRate": model.player?.rate ?? -1]
      } else { checks["liveQualitySwitchHasTwoAvailableLevels"] = false }
    }
    diagnostics["resolution"] = model.smokePlaybackResolution
    diagnostics["responseObservations"] = model.smokePlaybackFailureDetails
    diagnostics["elapsed"] = model.elapsed; diagnostics["state"] = model.notice ?? model.playbackState
    diagnostics["audioFrames"] = probe?.result.frames ?? 0
    diagnostics["audioNonzeroSamples"] = probe?.result.nonzero ?? 0
    diagnostics["remoteStatistics"] = await model.smokeRemoteStatistics()
    diagnostics["preferredForwardBufferSeconds"] = model.player?.currentItem?.preferredForwardBufferDuration ?? -1
    if arguments.contains("--test-history") {
      model.saveProgress()
      checks["historyRealBilibiliStableReferenceRecorded"] = model.continueWatching.entries.contains {
        $0.context.sourceID == plugin.id && $0.context.reference == reference && $0.context.librarySource == nil && $0.progress.resumablePosition > 0
      }
    }
    if let signal = model.videoPresentation.signal, let data = try? JSONEncoder().encode(signal),
      let value = try? JSONSerialization.jsonObject(with: data) { diagnostics["sourceSignal"] = value }
    if arguments.contains("--test-history"), let entry = model.continueWatching.entries.first(where: { $0.context.sourceID == plugin.id && $0.context.reference == reference }) {
      model.stopPlayback(); model.detail = nil; model.navigate(.home); model.continueWatching.open(entry.id)
      for _ in 0..<100 { if model.detail != nil || model.notice != nil { break }; try? await Task.sleep(for: .milliseconds(50)) }
      checks["historyRealBilibiliCardReopensStableReference"] = model.detail?.source == plugin.id && model.detail?.reference == reference && model.historyReturnEntryID == entry.id
    }
    return (checks, diagnostics)
  }
}

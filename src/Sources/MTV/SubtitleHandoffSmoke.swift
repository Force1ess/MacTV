import AppKit
import AVFoundation
import MTVCore

extension UISmoke {
  static func subtitleHandoffSmoke(model: AppModel, output: URL) async -> [String: Bool] {
    var checks: [String: Bool] = [:], observations: [String: Any] = [:]
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<250 { if condition() { return }; try? await Task.sleep(for: .milliseconds(40)) }
    }
    await wait { !model.libraryRefreshing }
    let source = model.captureLibrarySource(), preference = model.preferredEngine
    let rate = model.playbackRate, volume = model.playbackVolume
    defer { model.stopPlayback(); model.playbackRate = rate; model.playbackVolume = volume; model.preferredEngine = preference; model.restoreLibrarySource(source); model.notice = nil; model.navigate(.home) }
    let fixtures = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures")
    for (name, path) in [("SDR", "codec-matrix-v1/h264-aac.mp4"), ("PQ", "HDR-v1/PQ.mp4"), ("HLG", "HDR-v1/HLG-Auto.mp4"), ("Invalid", "codec-matrix-v1/h264-aac.mp4"), ("ManualPQ", "HDR-v1/PQ.mp4")] {
      do {
        let folder = output.appendingPathComponent(name), file = folder.appendingPathComponent("Film.mp4")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent(path), to: file)
        model.useLocalRoot(folder); await wait { !model.libraryRefreshing }; await model.waitForSourceSave()
        model.preferredEngine = .system; model.notice = nil
        let identity = "owned-handoff-" + name
        model.beginPlayback(url: file, item: MediaItem(id: identity, title: name + "字幕衔接", url: file.absoluteString), fromBeginning: true)
        await wait { model.playingItem?.id == identity && model.player?.currentItem?.status == .readyToPlay && model.elapsed > 0.2 }
        checks[name + "-startsWithActualSystemPlayer"] = model.player != nil && model.elapsed > 0
        model.applyPlaybackRate(1.5); model.setPlaybackVolume(0.4)
        model.playerCommand(1); await wait { model.paused }
        await wait { model.automaticSubtitleTask != nil }; await model.automaticSubtitleTask?.value
        let position = model.player?.currentTime().seconds ?? -100
        let caption = folder.appendingPathComponent("Film.zh.srt")
        let text = name == "Invalid" ? "This is not a subtitle file." : "1\n00:00:00,000 --> 00:00:20,000\nMTV HANDOFF \(name)\n"
        try Data(text.utf8).write(to: caption)
        guard let context = model.localSubtitleContext else { throw CocoaError(.fileReadNoPermission) }
        let listing = try await model.subtitleFiles.discover(for: file, access: context.access)
        guard let candidate = listing.candidates.first else { throw CocoaError(.fileReadUnknown) }
        let prepared = try await model.subtitleFiles.prepare(candidate, access: context.access)
        let automatic = name != "ManualPQ"
        checks[name + "-handoffAccepted"] = model.restartForSubtitle(prepared, context: context, automatic: automatic)
        await wait { (model.mpvEngine?.subtitle != nil || model.mpvEngine?.subtitleError != nil) && model.mpvEngine?.latest?.paused == true }
        guard let engine = model.mpvEngine else { throw CocoaError(.featureUnsupported) }
        checks[name + "-usesMPVWithoutVLC"] = model.player == nil && model.vlcEngine == nil && engine.latest?.vo == "gpu-next"
        checks[name + "-sameVideoIdentityAndPausePreserved"] = model.playingItem?.id == identity && model.paused && engine.latest?.paused == true
        checks[name + "-userSelectionIntentPreserved"] = model.hasUserSubtitleChoice == !automatic
        checks[name + "-doesNotChangeGlobalPlayerPreference"] = model.preferredEngine == .system
        checks[name + "-speedPreservedInBackend"] = abs((Double(await engine.diagnostic("speed")) ?? 0) - 1.5) < 0.01
        checks[name + "-volumePreservedInBackend"] = await engine.diagnostic("volume") == "40.000000"
        let at = Double(await engine.diagnostic("time-pos")) ?? -100
        try await Task.sleep(for: .milliseconds(350))
        let still = Double(await engine.diagnostic("time-pos")) ?? -100
        checks[name + "-actualPositionPreserved"] = abs(at - position) < 0.3 && abs(at - still) < 0.05
        let tracks = await engine.tracks(subtitles: true)
        if name == "Invalid" {
          checks["invalidCaptionDoesNotCloseVideo"] = engine.subtitleError != nil && engine.subtitle == nil && model.notice == nil
        } else { checks[name + "-preparedCaptionActuallySelected"] = tracks.selectedID > 0 && tracks.selectedExternalURL == caption }
        let rawParams = await engine.diagnostic("video-params")
        if name == "PQ" || name == "HLG" || name == "ManualPQ" {
          let params = (try? JSONSerialization.jsonObject(with: Data(rawParams.utf8))) as? [String: Any]
          checks[name + "-tenBitHDRMetadataRetained"] = params?["hw-pixelformat"] as? String == "p010"
            && params?["primaries"] as? String == "bt.2020" && params?["gamma"] as? String == "pq"
          if name == "HLG" { checks["HLG-dolbyVisionMetadataRetained"] = params?["colormatrix"] as? String == "dolbyvision" }
        }
        observations[name] = ["positionBefore": position, "positionAfter": at,
          "videoParams": rawParams, "hwdec": await engine.diagnostic("hwdec-current"),
          "physicalHDROutputVerified": false]
        try await engine.screenshot(output.appendingPathComponent(name + "-caption.png"))
        model.playerCommand(1); await wait { (engine.latest?.elapsed ?? 0) > at + 0.2 }
        checks[name + "-resumesRealTimeline"] = (engine.latest?.elapsed ?? 0) > at + 0.2
        model.stopPlayback(); await engine.waitUntilStopped()
      } catch {
        checks[name + "-handoffCompleted"] = false
        observations[name] = ["error": error.localizedDescription, "notice": model.notice ?? ""]
        let engine = model.mpvEngine; model.stopPlayback(); await engine?.waitUntilStopped()
      }
    }
    if let data = try? JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("subtitle-handoff-observations.json"))
    }
    return checks
  }
}

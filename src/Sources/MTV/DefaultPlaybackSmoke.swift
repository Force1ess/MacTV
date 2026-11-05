import AppKit
import AVFoundation
import MTVCore

extension UISmoke {
  static func defaultPlaybackSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    let source = model.captureLibrarySource(), oldEngine = model.preferredEngine
    var checks: [String: Bool] = [:], observations: [String: Any] = [:]
    defer { model.stopPlayback(); model.preferredEngine = oldEngine; model.restoreLibrarySource(source); model.notice = nil; model.navigate(.home) }
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<300 { if condition() { break }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    func stopPlayer() async {
      let vlc = model.vlcEngine, mpv = model.mpvEngine
      model.stopPlayback()
      await vlc?.waitUntilStopped(); await mpv?.waitUntilStopped()
    }
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/codec-matrix-v1")
    for engine in [PlaybackEngineChoice.system, .vlc, .mpv] {
      await stopPlayer(); model.preferredEngine = engine
      let file = root.appendingPathComponent("h264-two-subtitles.mp4")
      let identity = "owned-default-" + engine.rawValue
      model.notice = nil
      model.beginPlayback(url: file, item: MediaItem(id: identity, title: "字幕与遥控验证", url: file.absoluteString))
      await wait { (model.playingItem?.id == identity && model.playbackPresented && model.elapsed > 0.4) || model.notice != nil }
      checks["defaultPlaybackStarts-" + engine.rawValue] = model.playbackPresented && model.elapsed > 0 && model.notice == nil
      model.playerCommand(1); await wait { model.paused }
      model.playerCommand(4); await wait { model.playbackTracks.isPresented && !model.playbackTracks.loading }
      let menu = model.playbackTracks
      let options = menu.options.filter { ($0.trackID ?? -1) >= 0 }
      observations[engine.rawValue] = ["selected": menu.selectedID, "titles": options.map(\.title),
        "ids": options.compactMap(\.trackID), "notice": model.notice ?? "", "elapsed": model.elapsed,
        "actualEngine": model.mpvEngine != nil ? "mpv" : (model.vlcEngine != nil ? "vlc" : "system")]
      // AVFoundation exposes normal and forced variants for each source track.
      let languages = Set(options.compactMap { SubtitlePreference.language($0.title) })
      checks["defaultSubtitleSelected-" + engine.rawValue] = menu.selectedID >= 0
        && languages.isSuperset(of: ["en", "zh"]) && (engine == .system ? options.count >= 2 : options.count == 2)
      if let selected = options.first(where: { $0.trackID == menu.selectedID }) {
        let ranks = options.map { SubtitlePreference.rank(language: nil, title: $0.title) }
        checks["defaultSubtitleRespectsLanguageOrder-" + engine.rawValue] = SubtitlePreference.rank(language: nil, title: selected.title) == ranks.min()
      } else { checks["defaultSubtitleRespectsLanguageOrder-" + engine.rawValue] = false }
      while menu.selection > 0 { model.handle(.up) }; model.handle(.select)
      await wait { !menu.isPresented }; try? await Task.sleep(for: .milliseconds(700))
      model.playerCommand(4); await wait { menu.isPresented && !menu.loading }
      checks["explicitSubtitleOffStaysOff-" + engine.rawValue] = menu.selectedID == -1
      model.handle(.back)
      checks["subtitleMenuBackKeepsPlayback-" + engine.rawValue] = !menu.isPresented && model.playbackPresented
      model.showPlayerControls()
      if let mpv = model.mpvEngine, let native = mpv.windowForTesting() { capture(native, to: output.appendingPathComponent(engine.rawValue + "-controls.png")) }
      else { capture(window, to: output.appendingPathComponent(engine.rawValue + "-controls.png")) }
      model.handle(.back)
      checks["firstBackHidesControls-" + engine.rawValue] = model.playbackPresented && !model.playerControlsVisible
      model.handle(.back); await stopPlayer()
      checks["secondBackReturnsToLibrary-" + engine.rawValue] = !model.playbackPresented
    }
    do {
      let folder = output.appendingPathComponent("OwnedSidecars")
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let file = folder.appendingPathComponent("Film.mp4")
      try FileManager.default.copyItem(at: root.appendingPathComponent("h264-aac.mp4"), to: file)
      let code = SubtitlePreference.playerLanguages.split(separator: ",").first.map(String.init) ?? "en"
      try Data("1\n00:00:00,000 --> 00:00:09,000\nMTV AUTO PREFERRED\n".utf8).write(to: folder.appendingPathComponent("Film." + code + ".srt"))
      model.mediaRoot = folder.path; model.preferredEngine = .mpv
      model.beginPlayback(url: file, item: MediaItem(id: "owned-default-sidecar", title: "自动外挂字幕", url: file.absoluteString))
      await wait { model.mpvEngine?.subtitle != nil || model.notice != nil }
      checks["mpvAutomaticallyLoadsAvailableSidecar"] = model.mpvEngine?.subtitle?.source.filename == "Film." + code + ".srt"
      if let engine = model.mpvEngine {
        let tracks = await engine.tracks(subtitles: true)
        checks["mpvAutoSidecarSelectedInActualBackend"] = tracks.selectedID > 0 && tracks.selectedExternalURL == engine.subtitle?.source.url
        checks["mpvAutoSidecarUsesOwnedPreparedCopy"] = engine.subtitle?.url.path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/PlaybackSubtitles").path + "/") == true
        try await Task.sleep(for: .milliseconds(400))
        try await engine.screenshot(output.appendingPathComponent("mpv-auto-caption-rendered.png"))
      }
    } catch { checks["ownedSidecarFixtureCompleted"] = false }
    await stopPlayer()
    if let data = try? JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("default-playback-observations.json"))
    }
    return checks
  }
}

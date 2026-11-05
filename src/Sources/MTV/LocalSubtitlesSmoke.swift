import AVFoundation
import AppKit
import MTVCore
import Vision

extension UISmoke {
  static func localSubtitlesSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    let original = model.captureLibrarySource(), previous = model.preferredEngine
    defer { model.stopPlayback(); model.preferredEngine = previous; model.notice = nil; model.detail = nil; model.restoreLibrarySource(original); model.navigate(.home) }
    var checks: [String: Bool] = [:], copies: [URL] = []
    var textEvidence: [String: [String]] = [:]
    func containsCaption(_ actual: String, _ expected: String) -> Bool {
      func normalized(_ value: String) -> String { value.replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression).lowercased() }
      return actual.components(separatedBy: "\n").contains { normalized($0).contains(normalized(expected)) }
    }
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<240 { if condition() { return }; try? await Task.sleep(for: .milliseconds(40)) }
    }
    func snapshotText(_ engine: VLCPlaybackEngine, name: String) async -> String {
      let file = output.appendingPathComponent(name + ".png")
      guard await engine.snapshot(to: file) else { return "" }
      var image: CGImage?
      for _ in 0..<100 {
        image = NSImage(contentsOf: file)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        if image != nil { break }; try? await Task.sleep(for: .milliseconds(30))
      }
      guard let image else { return "" }
      var observations: [String] = []
      for scale in [1, 4] {
        let source: CGImage
        if scale == 1 { source = image }
        else {
          guard let context = CGContext(data: nil, width: image.width * scale, height: image.height * scale,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
          context.interpolationQuality = .none
          context.draw(image, in: CGRect(x: 0, y: 0, width: image.width * scale, height: image.height * scale))
          guard let enlarged = context.makeImage() else { continue }; source = enlarged
        }
        for language in ["en-US", "zh-Hans"] {
          let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
          request.recognitionLanguages = [language]; request.usesLanguageCorrection = language == "zh-Hans"
          do {
            try VNImageRequestHandler(cgImage: source).perform([request])
            observations.append((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " "))
          } catch { observations.append("OCR failed") }
        }
      }
      textEvidence[name] = observations
      return observations.joined(separator: "\n")
    }
    func selectFile(_ name: String) async -> Bool {
      model.playerButton = 4; model.handle(.select)
      await wait { model.playbackTracks.isPresented && !model.playbackTracks.loading }
      let menu = model.playbackTracks
      guard let index = menu.options.firstIndex(where: { $0.subtitle?.filename == name }) else { return false }
      while menu.selection < index { model.handle(.down) }; while menu.selection > index { model.handle(.up) }
      model.handle(.select)
      await wait { model.vlcEngine?.subtitle?.source.filename == name && (model.vlcEngine?.latest?.subtitleID ?? -1) >= 0 && model.vlcEngine?.latest?.state == 4 }
      return model.vlcEngine?.subtitle?.source.filename == name && (model.vlcEngine?.latest?.subtitleID ?? -1) >= 0
    }
    do {
      let root = output.appendingPathComponent("owned-caption-fixture")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/IndependentLongGOP45-v1.mp4")
      let media = root.appendingPathComponent("Caption.mp4")
      try FileManager.default.copyItem(at: fixture, to: media)
      let short = root.appendingPathComponent("Short.mp4")
      try FileManager.default.copyItem(at: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/PlaybackFixture.mp4"), to: short)
      let srt = "1\n00:00:00,000 --> 00:00:44,500\nMTV EXTERNAL SRT\n"
      try Data(srt.utf8).write(to: root.appendingPathComponent("Short.en.srt"))
      let ass = """
      [Script Info]
      ScriptType: v4.00+
      PlayResX: 640
      PlayResY: 360
      [V4+ Styles]
      Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
      Style: Default,Arial,28,&H00FFFFFF,&H000000FF,&H00000000,&H64000000,0,0,0,0,100,100,0,0,1,2,0,2,10,10,24,1
      [Events]
      Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
      Dialogue: 0,0:00:00.00,0:00:44.50,Default,,0,0,0,,MTV EXTERNAL ASS
      """
      let ssa = """
      [Script Info]
      ScriptType: v4.00
      [V4 Styles]
      Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, TertiaryColour, BackColour, Bold, Italic, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, AlphaLevel, Encoding
      Style: Default,Arial,28,16777215,255,0,0,0,0,1,2,0,2,10,10,24,0,1
      [Events]
      Format: Marked, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
      Dialogue: Marked=0,0:00:00.00,0:00:44.50,Default,,0,0,0,,MTV EXTERNAL SSA
      """
      for (name, text) in [("Caption.en.srt", srt), ("Caption.zh.ass", ass), ("Caption.old.ssa", ssa),
        ("Caption.utf8.srt", "1\n00:00:00,000 --> 00:00:44,500\n外挂中文字幕已启用\n"),
        ("Caption.invalid.vtt", "invalid WebVTT fixture"),
        ("Caption.web.vtt", "WEBVTT\n\n00:00.000 --> 00:44.500\nMTV EXTERNAL VTT\n")] {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
      }
      let outside = output.appendingPathComponent("outside-caption.srt")
      try Data(srt.utf8).write(to: outside)
      try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Caption.escape.srt"), withDestinationURL: outside)
      model.useLocalRoot(root); await wait { !model.libraryRefreshing }; await model.waitForSourceSave()
      let item = MediaItem(id: media.path, title: "自建外挂字幕", url: media.absoluteString)
      model.preferredEngine = .vlc
      model.beginPlayback(url: media, item: MediaItem(id: "owned-caption-autoload-check", title: "自建默认字幕检查", url: media.absoluteString), fromBeginning: true)
      await wait { model.vlcEngine?.subtitle != nil && (model.vlcEngine?.latest?.displayedPictures ?? 0) > 0 }
      if let engine = model.vlcEngine {
        let native = await engine.tracks(subtitles: true)
        checks["sidecarVLCAutomaticallyLoadsAvailableCaption"] = engine.subtitle != nil && native.selectedID >= 0
      } else { checks["sidecarVLCAutomaticallyLoadsAvailableCaption"] = false }
      model.stopPlayback()
      // Manual-import coverage: captions arrive after the video has opened.
      // Keep all files inside this test's owned directory; no user media changes.
      let held = output.appendingPathComponent("CaptionsAddedAfterPlayback")
      try FileManager.default.createDirectory(at: held, withIntermediateDirectories: true)
      let captionNames = ["Caption.en.srt", "Caption.zh.ass", "Caption.old.ssa", "Caption.utf8.srt", "Caption.invalid.vtt", "Caption.web.vtt"]
      for name in captionNames { try FileManager.default.moveItem(at: root.appendingPathComponent(name), to: held.appendingPathComponent(name)) }
      model.preferredEngine = .system; model.resumeStore.save(12, for: item.id, duration: 45)
      model.beginPlayback(url: media, item: item)
      await wait { (model.player?.currentTime().seconds ?? 0) >= 12 && model.testDecodedFrame() != nil }
      await wait { model.automaticSubtitleTask != nil }
      await model.automaticSubtitleTask?.value
      let manualInitial: [String: Any] = ["systemPlayer": model.player != nil, "vlcPlayer": model.vlcEngine != nil,
        "autoTaskScheduled": model.automaticSubtitleTask != nil, "notice": model.notice ?? "",
        "loadedSubtitle": model.vlcEngine?.subtitle?.source.filename ?? ""]
      if let data = try? JSONSerialization.data(withJSONObject: manualInitial, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("manual-caption-initial.json"))
      }
      for name in captionNames { try FileManager.default.moveItem(at: held.appendingPathComponent(name), to: root.appendingPathComponent(name)) }
      model.playerCommand(1); await settle()
      let position = model.player?.currentTime().seconds ?? -100
      // Retain explicit VLC compatibility coverage; default handoff uses MPV.
      model.preferredEngine = .vlc
      model.playerButton = 4; model.handle(.select); await wait { !model.playbackTracks.loading }
      checks["sidecarsListedAlongsideSystemTracksWithoutChangingEngine"] = model.player != nil && model.vlcEngine == nil
        && model.playbackTracks.options.filter { $0.subtitle != nil }.count == 6
        && model.playbackTracks.selectedID == -1 && model.playbackTracks.selectedExternalURL == nil
      checks["sidecarSystemChoiceExplainsEngineTransitionAndEscapeIsAbsent"] = model.playbackTracks.options.filter { $0.subtitle != nil }.allSatisfy { $0.detail.contains("通用播放器") }
        && !model.playbackTracks.options.contains { $0.subtitle?.filename.contains("escape") == true }
      await settle(); capture(window, to: output.appendingPathComponent("sidecars-system-menu.png"))
      model.handle(.back)
      checks["sidecarMenuBackDoesNotStartOrEnableAnything"] = model.player != nil && model.vlcEngine == nil && model.paused
      let selected = await selectFile("Caption.en.srt")
      checks["sidecarSelectionHonorsExplicitVLCPreference"] = selected && model.player == nil && model.preferredEngine == .vlc
      checks["sidecarTransitionPreservesPausedPosition"] = model.paused && model.vlcEngine?.latest?.state == 4
        && abs((model.vlcEngine?.latest?.elapsed ?? -100) - position) <= 2 && model.playbackInterruption == nil
      var srtRendered = false
      if let engine = model.vlcEngine, let prepared = engine.subtitle {
        copies.append(prepared.url)
        let data = try Data(contentsOf: prepared.url)
        checks["sidecarPlayerReceivesPrivateSnapshotNotOriginalPath"] = prepared.url != prepared.source.url && data == Data(srt.utf8)
        srtRendered = containsCaption(await snapshotText(engine, name: "sidecar-srt-rendered"), "MTV EXTERNAL SRT")
        checks["sidecarSRTTextAppearsInActualVideoSnapshot"] = srtRendered
        model.playerButton = 4; model.handle(.select); await wait { !model.playbackTracks.loading }
        checks["sidecarReopeningMarksSelectedFile"] = model.playbackTracks.selectedExternalURL == prepared.source.url
        while model.playbackTracks.selection > 0 { model.handle(.up) }; model.handle(.select)
        await wait { engine.latest?.subtitleID == -1 }
        model.playerCommand(1); try? await Task.sleep(for: .milliseconds(250)); model.playerCommand(1); await settle()
        checks["sidecarOffClearsTrackWithoutRestartingReadyPlayer"] = model.vlcEngine === engine && engine.latest?.subtitleID == -1
        let offText = await snapshotText(engine, name: "sidecar-srt-off")
        checks["sidecarOffRemovesPreviouslyObservedText"] = srtRendered && !containsCaption(offText, "MTV EXTERNAL SRT")
        try Data("changed original".utf8).write(to: prepared.source.url)
        checks["sidecarLoadedSnapshotSurvivesOriginalChange"] = try Data(contentsOf: prepared.url) == Data(srt.utf8)
      }
      for (name, text) in [("Caption.zh.ass", "MTV EXTERNAL ASS"), ("Caption.old.ssa", "MTV EXTERNAL SSA"),
        ("Caption.web.vtt", "MTV EXTERNAL VTT"), ("Caption.utf8.srt", "外挂中文字幕已启用")] {
        let success = await selectFile(name)
        checks["sidecar-\(name)-selectsAndPreservesPause"] = success && model.paused && model.playbackInterruption == nil
        if let engine = model.vlcEngine, let prepared = engine.subtitle {
          copies.append(prepared.url)
          checks["sidecar-\(name)-actualTextRendered"] = containsCaption(await snapshotText(engine, name: "rendered-" + name), text)
        } else { checks["sidecar-\(name)-actualTextRendered"] = false }
      }
      do {
        let before = model.vlcEngine
        model.playerButton = 4; model.handle(.select); await wait { !model.playbackTracks.loading }
        if let index = model.playbackTracks.options.firstIndex(where: { $0.subtitle?.filename == "Caption.invalid.vtt" }) {
          while model.playbackTracks.selection < index { model.handle(.down) }; while model.playbackTracks.selection > index { model.handle(.up) }
          model.handle(.select); await wait { !model.playbackTracks.busy }
        }
        checks["sidecarMalformedVTTKeepsCurrentPlaybackAndAllowsReturn"] = model.playbackTracks.isPresented
          && !model.playbackTracks.message.isEmpty && model.vlcEngine === before && model.paused
        model.handle(.back)
      }
      model.stopPlayback(); await settle()
      await wait { copies.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) } }
      checks["sidecarOwnedSnapshotsCleanUpAfterPlayerReleasesThem"] = !copies.isEmpty && copies.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
      checks["sidecarOriginalFilesRemainInPlace"] = FileManager.default.fileExists(atPath: media.path)
        && FileManager.default.fileExists(atPath: root.appendingPathComponent("Caption.zh.ass").path)
      model.preferredEngine = .system
      model.beginPlayback(url: short, item: MediaItem(id: short.path, title: "自建短片自动字幕", url: short.absoluteString), fromBeginning: true)
      await wait { (model.mpvEngine?.subtitle ?? model.vlcEngine?.subtitle)?.source.filename == "Short.en.srt" }
      checks["sidecarShortClipAutomaticTransitionPreservesPlayback"] = (model.mpvEngine?.subtitle ?? model.vlcEngine?.subtitle)?.source.filename == "Short.en.srt"
        && model.playbackInterruption == nil && !model.hasUserSubtitleChoice
      model.stopPlayback()
      try FileManager.default.moveItem(at: root.appendingPathComponent("Short.en.srt"), to: held.appendingPathComponent("Short.en.srt"))
      model.beginPlayback(url: short, item: MediaItem(id: short.path, title: "自建短片外挂", url: short.absoluteString), fromBeginning: true)
      await wait { (model.player?.currentTime().seconds ?? 0) > 0.5 && model.testDecodedFrame() != nil }
      await wait { model.automaticSubtitleTask != nil }
      await model.automaticSubtitleTask?.value
      try FileManager.default.moveItem(at: held.appendingPathComponent("Short.en.srt"), to: root.appendingPathComponent("Short.en.srt"))
      model.playerCommand(1); await settle()
      let shortPosition = model.player?.currentTime().seconds ?? -100
      model.preferredEngine = .vlc
      let shortSelected = await selectFile("Short.en.srt")
      checks["sidecarShortClipTransitionDoesNotTriggerStaleResumeGuard"] = shortSelected && model.playbackInterruption == nil
        && model.paused && abs((model.vlcEngine?.latest?.elapsed ?? -100) - shortPosition) <= 2
      model.stopPlayback()
      await model.waitForSourceSave()
    } catch {
      checks["sidecarOwnedFixtureFlowCompleted"] = false
      try? Data(error.localizedDescription.utf8).write(to: output.appendingPathComponent("sidecar-error.txt"))
    }
    if let data = try? JSONSerialization.data(withJSONObject: textEvidence, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("caption-ocr-evidence.json"))
    }
    return checks
  }
}

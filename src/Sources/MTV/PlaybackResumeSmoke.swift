import AVFoundation
import AppKit
import MTVCore

extension UISmoke {
  static func playbackResumeSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    let previousEngine = model.preferredEngine
    defer { model.stopPlayback(); model.preferredEngine = previousEngine; model.notice = nil; model.detail = nil; model.navigate(.home) }
    var checks: [String: Bool] = [:]
    var phases: [String: [String: Any]] = [:]
    var vlcSamples: [[String: Any]] = []
    func observe(_ phase: String) {
      func finite(_ value: Double?) -> Double { value.flatMap { $0.isFinite ? $0 : nil } ?? -1 }
      phases[phase] = ["saved": model.resumeStore.position(for: "resume-choice-generated"),
        "elapsed": finite(model.elapsed), "duration": finite(model.duration),
        "playerTime": finite(model.player?.currentTime().seconds),
        "vlcTime": finite(model.vlcEngine?.latest?.elapsed), "vlcDuration": finite(model.vlcEngine?.latest?.duration),
        "vlcDecoded": model.vlcEngine?.latest?.decodedVideo ?? -1, "vlcDisplayed": model.vlcEngine?.latest?.displayedPictures ?? -1,
        "vlcInitialPosition": model.vlcEngine?.initialPosition ?? -1,
        "vlcSeeks": model.vlcEngine?.testSeekRequests ?? [],
        "detailPresent": model.detail != nil, "noticePresent": model.notice != nil, "loading": model.loading]
      if let data = try? JSONSerialization.data(withJSONObject: phases, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("resume-phases.json"), options: .atomic)
      }
    }
    let arguments = CommandLine.arguments
    let supplied = arguments.firstIndex(of: "--test-media").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    let fixture = supplied.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/MTV/Fixtures/IndependentLongGOP45-v1.mp4")
    let item = MediaItem(id: "resume-choice-generated", title: "夜航 · 续播体验", subtitle: "生成的 45 秒测试片",
      overview: "从上次位置继续，也可以重新开始。测试不会改动原始影片。", url: fixture.absoluteString)
    func seed() { model.resumeStore.save(12, for: item.id, source: item.source, duration: 45) }
    func waitForFrame(after start: Double, before end: Double, vlc: Bool = false) async -> Bool {
      var firstEligiblePictures: Int?
      for _ in 0..<180 {
        if model.notice != nil || model.playbackInterruption != nil { return false }
        if vlc {
          if let stats = model.vlcEngine?.latest, vlcSamples.count < 360 {
            vlcSamples.append(["phaseStart": start, "elapsed": stats.elapsed,
              "decoded": stats.decodedVideo, "displayed": stats.displayedPictures,
              "seeks": model.vlcEngine?.testSeekRequests ?? []])
            if let data = try? JSONSerialization.data(withJSONObject: vlcSamples, options: [.sortedKeys]) {
              try? data.write(to: output.appendingPathComponent("resume-vlc-samples.json"), options: .atomic)
            }
          }
          if let stats = model.vlcEngine?.latest, stats.decodedVideo > 0, stats.displayedPictures > 0,
            stats.elapsed >= start, stats.elapsed < end {
            if let firstEligiblePictures, stats.displayedPictures > firstEligiblePictures { return true }
            if firstEligiblePictures == nil { firstEligiblePictures = stats.displayedPictures }
          }
        } else if let player = model.player, player.currentItem?.status == .readyToPlay,
          player.currentTime().seconds >= start, player.currentTime().seconds < end,
          model.testDecodedFrame() != nil { return true }
        try? await Task.sleep(for: .milliseconds(100))
      }
      return false
    }
    for _ in 0..<300 { if !model.loading { break }; try? await Task.sleep(for: .milliseconds(50)) }
    model.stopPlayback(); model.navigate(.library); model.preferredEngine = .system
    seed(); model.selectContent(item)
    checks["resumeDetailOffersContinueRestartMetadataAndClose"] = model.resumeRecord(for: item)?.resumablePosition == 12
      && model.detailControls(for: item) == [.play, .restart, .metadata, .close] && !model.canWatchlist(item)
    await settle(); capture(window, to: output.appendingPathComponent("resume-detail.png"))
    observe("before-system-continue")
    model.handle(.select)
    checks["resumeSystemContinueDecodesAtSavedPosition"] = await waitForFrame(after: 12.25, before: 17)
    observe("after-system-continue")
    model.stopPlayback(); seed(); model.selectContent(item)
    model.handle(.right); model.handle(.select)
    checks["resumeSystemRestartDecodesNearBeginning"] = await waitForFrame(after: 0.25, before: 4)
    observe("after-system-restart")
    model.stopPlayback()
    checks["resumeRestartSavesNewPositionAfterPlayback"] = model.resumeStore.position(for: item.id) < 5
    seed()
    var missing = item; missing.url = output.appendingPathComponent("missing-owned-fixture.mp4").absoluteString
    model.selectContent(missing); model.handle(.right); model.handle(.select)
    for _ in 0..<180 { if model.notice != nil || model.playbackInterruption != nil { break }; try? await Task.sleep(for: .milliseconds(50)) }
    observe("after-missing-restart")
    checks["resumeFailedRestartDoesNotEraseOldPosition"] = (model.notice != nil || model.playbackInterruption != nil) && model.resumeStore.position(for: item.id) == 12
    model.notice = nil; model.stopPlayback()
    seed()
    var shorter = item; shorter.url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/MTV/Fixtures/PlaybackFixture.mp4").absoluteString
    model.selectContent(shorter); model.handle(.select)
    for _ in 0..<120 { if model.playbackInterruption != nil { break }; try? await Task.sleep(for: .milliseconds(50)) }
    checks["resumeChangedShorterSourceCannotPretendToContinue"] = model.playbackInterruption?.contains("长度") == true
    model.stopPlayback()
    checks["resumeChangedSourceKeepsOriginalPositionAfterStop"] = model.resumeStore.position(for: item.id) == 12
    if VLCPlaybackEngine.isAvailable {
      model.preferredEngine = .vlc; seed(); model.selectContent(item); model.handle(.select)
      checks["resumeVLCContinueDecodesAtSavedPosition"] = await waitForFrame(after: 12.25, before: 17, vlc: true)
      observe("after-vlc-continue")
      model.stopPlayback(); seed(); model.selectContent(item); model.handle(.right); model.handle(.select)
      checks["resumeVLCRestartDecodesNearBeginning"] = await waitForFrame(after: 0.25, before: 4, vlc: true)
      observe("after-vlc-restart")
      model.stopPlayback()
    } else { checks["resumeVLCAvailableForBothStartingPoints"] = false }
    seed(); model.selectContent(item)
    model.handle(.right); model.handle(.right)
    checks["resumeExtraButtonKeepsMetadataRemoteReachable"] = model.detailAction == 2
      && model.detailControls(for: item)[model.detailAction] == .metadata
    model.handle(.right); model.handle(.right); model.handle(.select)
    checks["resumeCloseRemainsReachableAndBounded"] = model.detail == nil
    if let example = model.plugins.first(where: { $0.id == "mtv.example" }) {
      model.openModule(example)
      for _ in 0..<200 { if !model.loading { break }; try? await Task.sleep(for: .milliseconds(50)) }
      if let card = model.online.first {
        model.resumeStore.save(12, for: card.id, source: example.id, duration: 45)
        checks["resumePluginCannotReadOtherPluginSameID"] = model.resumeStore.position(for: card.id, source: "some.other") == 0
        model.selectContent(card)
        checks["resumePluginCollectionMovesAfterRestart"] = model.detailControls(for: card) == [.play, .restart, .collection, .watchlist, .close]
        model.handle(.right); model.handle(.right); model.handle(.select)
        for _ in 0..<200 { if !model.loading { break }; try? await Task.sleep(for: .milliseconds(50)) }
        checks["resumePluginCollectionStillOpensByRemote"] = model.modulePath.count == 1 && model.online.count == 2 && model.detail == nil
      } else { checks["resumeExampleLoaded"] = false }
    } else { checks["resumeExampleInstalled"] = false }
    model.stopPlayback(); model.notice = nil
    let orphan = MediaItem(id: "orphan-module", title: "已移除模块", url: fixture.absoluteString, source: "removed.plugin")
    model.play(orphan)
    checks["resumeUnknownPluginCannotUseLocalFilePlaybackPath"] = model.notice != nil && !model.preparingPlayback && !model.playbackPresented
    return checks
  }

  static func playbackResumeMismatchSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    guard CommandLine.arguments.contains("--test-vlc-native-reader") else { return ["resumeMismatchExplicitNativeDiagnosticRequired": false] }
    let previousEngine = model.preferredEngine
    defer { model.stopPlayback(); model.preferredEngine = previousEngine; model.notice = nil; model.detail = nil; model.navigate(.home) }
    for _ in 0..<300 { if !model.loading { break }; try? await Task.sleep(for: .milliseconds(50)) }
    model.stopPlayback(); model.navigate(.library); model.preferredEngine = .vlc
    let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/ResumeChoice45-v1.mp4")
    let item = MediaItem(id: "resume-mismatch-owned-edit", title: "拼接测试片 · 定位保护", url: fixture.absoluteString)
    model.resumeStore.save(12, for: item.id, duration: 45)
    model.selectContent(item); model.handle(.select)
    for _ in 0..<150 { if model.playbackInterruption != nil { break }; try? await Task.sleep(for: .milliseconds(100)) }
    var checks = ["resumeMismatchShowsExplicitFailure": model.playbackInterruption?.contains("准确恢复") == true,
      "resumeMismatchKeepsChosenEngineAndOriginalProgress": model.vlcEngine != nil && model.player == nil && model.resumeStore.position(for: item.id) == 12]
    for _ in 0..<30 { if model.vlcEngine?.latest?.state == 4 { break }; try? await Task.sleep(for: .milliseconds(100)) }
    checks["resumeMismatchActuallyPausesEngine"] = model.vlcEngine?.latest?.state == 4
    await settle(); capture(window, to: output.appendingPathComponent("resume-position-mismatch.png"))
    model.stopPlayback()
    checks["resumeMismatchStopCannotOverwriteWithWrongPosition"] = model.resumeStore.position(for: item.id) == 12
    model.selectContent(item); model.handle(.right); model.handle(.select)
    var decoded = false
    for _ in 0..<120 {
      if let stats = model.vlcEngine?.latest, stats.decodedVideo > 0 && stats.displayedPictures > 0,
        stats.elapsed >= 0.25 && stats.elapsed < 4 { decoded = true; break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    checks["resumeMismatchCanExplicitlyStartFromBeginning"] = decoded && model.playbackInterruption == nil
    return checks
  }
}

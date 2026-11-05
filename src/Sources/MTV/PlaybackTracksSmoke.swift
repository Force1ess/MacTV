import AVFoundation
import AppKit
import MTVCore

extension UISmoke {
  static func chooseDifferentPlaybackTrack(model: AppModel, kind: PlaybackTrackKind) async -> Bool {
    model.playerCommand(kind == .audio ? 3 : 4)
    let menu = model.playbackTracks
    for _ in 0..<100 { if !menu.loading { break }; try? await Task.sleep(for: .milliseconds(20)) }
    guard let index = menu.options.firstIndex(where: { ($0.trackID ?? -1) >= 0 && $0.trackID != menu.selectedID }) else { menu.close(); return false }
    while menu.selection < index { model.handle(.down) }; while menu.selection > index { model.handle(.up) }
    model.handle(.select)
    for _ in 0..<100 { if !menu.isPresented { return true }; try? await Task.sleep(for: .milliseconds(20)) }
    return false
  }
  static func playbackTracksSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    let previous = model.preferredEngine
    defer { model.stopPlayback(); model.preferredEngine = previous; model.notice = nil; model.detail = nil; model.navigate(.home) }
    var checks: [String: Bool] = [:]
    var progressEvidence: [[String: Any]] = []
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<200 { if condition() { return }; try? await Task.sleep(for: .milliseconds(30)) }
    }
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/codec-matrix-v1")
    for choice in [PlaybackEngineChoice.system, .vlc] {
      for subtitles in [false, true] {
        model.stopPlayback(); model.preferredEngine = choice
        let kind: PlaybackTrackKind = subtitles ? .subtitles : .audio
        let prefix = "tracks-\(choice.rawValue)-\(subtitles ? "subtitles" : "audio")"
        let file = root.appendingPathComponent(subtitles ? "h264-two-subtitles.mp4" : "h264-two-audio.mp4")
        model.beginPlayback(url: file, item: MediaItem(id: "owned-" + prefix, title: "自建轨道选择检查", url: file.absoluteString))
        await wait { model.elapsed > 0.5 && model.playbackPresented }
        model.playerCommand(subtitles ? 4 : 3)
        let menu = model.playbackTracks
        await wait { menu.isPresented && !menu.loading }
        checks[prefix + "-listsActualOptionsWithNames"] = menu.options.filter { ($0.trackID ?? -1) >= 0 }.count >= (subtitles ? 1 : 2)
          && menu.options.allSatisfy { !$0.title.isEmpty }
        if subtitles { checks[prefix + "-defaultSelectsAvailableSubtitleAndKeepsOffOption"] = menu.selectedID >= 0 && menu.options.first?.trackID == -1 }
        let oldSelected = menu.selectedID
        await settle(); capture(window, to: output.appendingPathComponent(prefix + ".png"))
        model.handle(.back)
        checks[prefix + "-remoteBackOnlyClosesMenu"] = !menu.isPresented && model.playbackPresented
        let switched = await chooseDifferentPlaybackTrack(model: model, kind: kind)
        await settle()
        var actualSelected: Int32 = -999
        if let engine = model.vlcEngine {
          actualSelected = Int32(subtitles ? engine.latest?.subtitleID ?? -999 : engine.latest?.audioID ?? -999)
          checks[prefix + "-invalidBackendIDCannotChangeTrack"] = !(await engine.selectTrack(subtitles: subtitles, id: Int32.max))
        } else if let item = model.player?.currentItem,
          let group = try? await item.asset.loadMediaSelectionGroup(for: subtitles ? .legible : .audible),
          let selected = item.currentMediaSelection.selectedMediaOption(in: group) {
          actualSelected = group.options.firstIndex(of: selected).map(Int32.init) ?? -999
        }
        checks[prefix + "-confirmChangesActualBackendSelection"] = switched && actualSelected >= 0 && actualSelected != oldSelected
        model.playerCommand(subtitles ? 4 : 3); await wait { menu.isPresented && !menu.loading }
        checks[prefix + "-reopeningMarksActualSelectedTrack"] = menu.selectedID == actualSelected
        if subtitles {
          while menu.selection > 0 { model.handle(.up) }; model.handle(.select)
          await wait { !menu.isPresented }; await settle()
          if let engine = model.vlcEngine { checks[prefix + "-explicitOffChangesBackend"] = engine.latest?.subtitleID == -1 }
          else if let item = model.player?.currentItem, let group = try? await item.asset.loadMediaSelectionGroup(for: .legible) {
            checks[prefix + "-explicitOffChangesBackend"] = item.currentMediaSelection.selectedMediaOption(in: group) == nil
          } else { checks[prefix + "-explicitOffChangesBackend"] = false }
        } else { model.handle(.back) }
        if let engine = model.vlcEngine {
          let before = await engine.statisticsForTesting()?.displayedPictures ?? -1
          await wait { (engine.latest?.displayedPictures ?? -1) > before }
          let after = engine.latest?.displayedPictures ?? -1
          checks[prefix + "-playbackStillDecodes"] = before >= 0 && after > before
          progressEvidence.append(["case": prefix, "displayedPicturesBefore": before, "displayedPicturesAfter": after])
        } else {
          var baseline: PlaybackFrameObservation?
          await wait { baseline = model.smokeDecodedFrameObservation(); return baseline?.presentationTime != nil }
          let before = baseline?.presentationTime ?? -1
          var observed: PlaybackFrameObservation?
          await wait { observed = model.smokeDecodedFrameObservation(); return (observed?.presentationTime ?? -1) > before }
          let after = observed?.presentationTime ?? -1
          checks[prefix + "-playbackStillDecodes"] = before >= 0 && after > before
          progressEvidence.append(["case": prefix, "framePresentationTimeBefore": before, "framePresentationTimeAfter": after])
        }
      }
    }
    model.stopPlayback()
    let controller = model.playbackTracks
    controller.present(.audio, load: {
      try? await Task.sleep(for: .milliseconds(200))
      return PlaybackTrackMenu(options: [PlaybackTrackOption(id: 99, title: "迟到的旧轨道")], selectedID: 99)
    }, apply: { _ in true })
    model.handle(.back)
    controller.present(.subtitles, load: {
      PlaybackTrackMenu(options: [PlaybackTrackOption(id: -1, title: "字幕关闭")], selectedID: -1)
    }, apply: { _ in true })
    try? await Task.sleep(for: .milliseconds(300))
    checks["tracksLateOldLoadCannotReplaceNewMenu"] = controller.kind == .subtitles && controller.options.map(\.trackID) == [-1]
    controller.close()
    controller.present(.audio, load: {
      PlaybackTrackMenu(options: [PlaybackTrackOption(id: 1, title: "原音轨"), PlaybackTrackOption(id: 2, title: "已失效的音轨")], selectedID: 1)
    }, apply: { _ in false })
    await wait { !controller.loading }
    model.handle(.down); model.handle(.select); await wait { !controller.busy }
    checks["tracksRejectedSelectionKeepsOriginalCheckmarkAndAllowsBack"] = controller.isPresented && controller.selectedID == 1 && !controller.message.isEmpty
    model.handle(.back)
    controller.present(.audio, load: {
      PlaybackTrackMenu(options: [PlaybackTrackOption(id: 1, title: "等待应用的旧轨道")], selectedID: 1)
    }, apply: { _ in try? await Task.sleep(for: .milliseconds(200)); return true })
    await wait { !controller.loading }
    model.handle(.select); model.handle(.back)
    controller.present(.subtitles, load: {
      PlaybackTrackMenu(options: [PlaybackTrackOption(id: -1, title: "字幕关闭")], selectedID: -1)
    }, apply: { _ in true })
    try? await Task.sleep(for: .milliseconds(300))
    checks["tracksLateApplyCannotCloseOrChangeNewMenu"] = controller.isPresented && controller.kind == .subtitles && controller.selectedID == -1
    controller.close()
    if let data = try? JSONSerialization.data(withJSONObject: progressEvidence, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("tracks-frame-progress.json"))
    }
    return checks
  }
}

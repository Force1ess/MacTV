import AVFoundation
import AppKit
import MTVCore

extension UISmoke {
  static func episodeContinuationSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    let original = model.captureLibrarySource(), previous = model.preferredEngine
    defer { model.stopPlayback(); model.preferredEngine = previous; model.notice = nil; model.detail = nil; model.restoreLibrarySource(original); model.navigate(.home) }
    var checks: [String: Bool] = [:]
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<240 { if condition() { return }; try? await Task.sleep(for: .milliseconds(40)) }
    }
    func decoded() -> Bool {
      if let mpv = model.mpvEngine { return (mpv.latest?.frames ?? 0) > 0 }
      return model.testDecodedFrame() != nil
    }
    func finishNaturally() async {
      let target = max(0, model.duration - 0.4)
      if let player = model.player {
        _ = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play(); model.paused = false
      } else if let engine = model.mpvEngine { engine.seek(target); engine.pause(false) }
    }
    do {
      let root = output.appendingPathComponent("owned-episode-fixtures"), seriesRoot = root.appendingPathComponent("Show")
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/PlaybackFixture.mp4")
      for (folder, name) in [("Show/Season 1", "Demo.S01E01.Pilot"), ("Show/Season 1", "Demo.S01E02.CutA"),
        ("Show/Season 1", "Demo.S01E02.CutB"), ("Show/Season 1", "Demo.S01E04.Later"),
        ("Show/Season 2", "Demo.S02E01.Final"), ("Other/Season 1", "Demo.S01E02.Unrelated")] {
        let destination = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: destination.appendingPathComponent(name + ".mp4"))
      }
      for choice in [PlaybackEngineChoice.system, .mpv] {
        model.stopPlayback(); model.preferredEngine = choice
        model.useLocalRoot(root); await wait { !model.libraryRefreshing }; await model.waitForSourceSave()
        guard let first = model.library.first(where: { $0.id.hasSuffix("Demo.S01E01.Pilot.mp4") }),
          let second = model.library.first(where: { $0.id.hasSuffix("Demo.S01E02.CutA.mp4") }),
          let final = model.library.first(where: { $0.id.hasSuffix("Demo.S01E04.Later.mp4") }),
          let group = model.libraryCatalog.root.first(where: { $0.id.contains(seriesRoot.path) })
        else { throw MTVError.message("自建剧集未整理") }
        let prefix = "next-" + choice.rawValue
        model.navigate(.library); model.selectContent(group); model.play(first, fromBeginning: true)
        await wait { model.elapsed > 0.5 && decoded() }
        checks[prefix + "-firstFileDisablesPrevious"] = !model.canStepVideo(-1) && model.canStepVideo(1)
        await finishNaturally()
        await wait { model.playingItem?.id == second.id && decoded() }
        checks[prefix + "-actualEOFStartsNextFile"] = model.playingItem?.id == second.id && !model.playbackCompleted && decoded()
        checks[prefix + "-EOFStoresFinishedPosition"] = model.resumeStore.record(for: first.id)?.resumablePosition == 0
        model.stopPlayback(); model.play(final, fromBeginning: true)
        await wait { model.playingItem?.id == final.id && model.elapsed > 0.5 && decoded() }
        checks[prefix + "-lastFileDisablesNextDespiteAnotherSeason"] = !model.canStepVideo(1) && model.canStepVideo(-1)
        await finishNaturally()
        await wait { !model.playbackPresented }
        checks[prefix + "-lastFileReturnsToSameList"] = !model.playbackPresented
          && model.section == .library && model.libraryPath.last?.id == group.id
      }
      await model.waitForSourceSave()
    } catch {
      checks["nextEpisodeOwnedFixtureFlowCompleted"] = false
      try? Data(error.localizedDescription.utf8).write(to: output.appendingPathComponent("next-episode-error.txt"))
    }
    return checks
  }
}

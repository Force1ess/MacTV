import Foundation
import MTVCore

extension UISmoke {
  static func systemAudioScopedSmoke(model: AppModel, output: URL) async -> [String: Bool] {
    guard !CommandLine.arguments.contains("--test-vlc-system-audio") else { return ["scopedAudioMustNotForceInternalPath": false] }
    for _ in 0..<400 {
      if !model.loading && !model.libraryRefreshing { break }
      try? await Task.sleep(for: .milliseconds(25))
    }
    let original = model.captureLibrarySource()
    let previousEngine = model.preferredEngine
    defer { model.stopPlayback(); model.preferredEngine = previousEngine; model.restoreLibrarySource(original); model.navigate(.home) }
    var checks: [String: Bool] = [:], evidence: [String: Any] = [:]
    let root = SystemAudioWaveSource.ownedFixtureURL.deletingLastPathComponent().appendingPathComponent("scoped-system-audio-" + UUID().uuidString, isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let file = root.appendingPathComponent("Scoped Timeline.mp4")
      try FileManager.default.copyItem(at: SystemAudioWaveSource.ownedFixtureURL, to: file)
      for (label, access) in [("denied", ScopedFileAccess.denied), ("unrestricted", .unrestricted), ("outside", .within(output))] {
        do {
          let source = try await SystemAudioWaveSource.prepare(file: file, start: 0, access: access)
          source.cancel(); checks["scopedAudioRejects-" + label] = false
        } catch SystemAudioWaveIneligible.outsideScope { checks["scopedAudioRejects-" + label] = label == "outside" }
        catch { checks["scopedAudioRejects-" + label] = (error as NSError).code == NSFileReadNoPermissionError }
      }
      let mutable = root.appendingPathComponent("Mutable.mp4")
      try FileManager.default.copyItem(at: file, to: mutable)
      do {
        let source = try await SystemAudioWaveSource.prepare(file: mutable, start: 0, access: .within(root))
        defer { source.cancel() }
        let handle = try FileHandle(forWritingTo: mutable)
        try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
        do {
          _ = try await source.read(offset: 0, count: 4, consumer: UUID())
          checks["scopedAudioDetectsChangedFileBeforeDelivery"] = false
        } catch { checks["scopedAudioDetectsChangedFileBeforeDelivery"] = source.failureMessage != nil }
      }
      let matrix = SystemAudioWaveSource.ownedFixtureURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("codec-matrix-v1")
      do {
        let source = try await SystemAudioWaveSource.prepare(file: matrix.appendingPathComponent("h264-aac.mp4"), start: 0, access: .within(matrix), requireEdits: true)
        source.cancel(); checks["scopedAudioSingleEditNeedsNoAdaptation"] = false
      } catch SystemAudioWaveIneligible.unedited { checks["scopedAudioSingleEditNeedsNoAdaptation"] = true }
      catch { checks["scopedAudioSingleEditNeedsNoAdaptation"] = false }
      do {
        let source = try await SystemAudioWaveSource.prepare(file: matrix.appendingPathComponent("h264-two-audio.mp4"), start: 0, access: .within(matrix), requireEdits: true)
        source.cancel(); checks["scopedAudioMultiTrackKeepsOriginalStrategy"] = false
      } catch SystemAudioWaveIneligible.unsupported { checks["scopedAudioMultiTrackKeepsOriginalStrategy"] = true }
      catch { checks["scopedAudioMultiTrackKeepsOriginalStrategy"] = false }
      model.useLocalRoot(root)
      for _ in 0..<200 { if !model.libraryRefreshing { break }; try? await Task.sleep(for: .milliseconds(25)) }
      await model.waitForSourceSave()
      checks.merge(await systemAudioSessionSmoke(model: model, output: output, file: file, requiresInternalFlag: false)) { _, new in new }
      let target = root.deletingLastPathComponent().appendingPathComponent("owned-link-target-" + UUID().uuidString + ".mp4")
      let link = root.appendingPathComponent("Linked Timeline.mp4")
      try FileManager.default.copyItem(at: file, to: target)
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
      model.preferredEngine = .vlc
      model.beginPlayback(url: link, item: MediaItem(id: "owned-scoped-link", title: "自建链接影片", url: link.absoluteString), fromBeginning: true)
      for _ in 0..<160 {
        if (model.vlcEngine?.latest?.elapsed ?? 0) > 0.5 && (model.vlcEngine?.latest?.displayedPictures ?? 0) > 0 { break }
        if model.playbackInterruption != nil { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      if let engine = model.vlcEngine {
        checks["scopedAudioLinkKeepsExistingVideoBehavior"] = (engine.latest?.displayedPictures ?? 0) > 0 && model.playbackInterruption == nil
        checks["scopedAudioLinkDoesNotWidenDecoderScope"] = await engine.systemAudioOriginForTesting() == nil
          && model.playbackSelectionReason.contains("不在当前所选目录范围")
        model.stopPlayback(); await engine.waitUntilStopped()
      } else { checks["scopedAudioLinkKeepsExistingVideoBehavior"] = false }
      evidence["normalSourcePathUsed"] = checks["systemSessionNormalPathWithoutForceFlag"] == true
      evidence["realSMBMountTested"] = false
      evidence["ownedFixtureDirectory"] = root.path
      if checks.values.allSatisfy({ $0 }) { try FileManager.default.removeItem(at: target); try FileManager.default.removeItem(at: root) }
      else { evidence["keptFailedFixtureForInspection"] = true; evidence["linkedTarget"] = target.path }
    } catch { checks["scopedAudioFlowCompleted"] = false; evidence["error"] = error.localizedDescription }
    if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("system-audio-scoped.json"))
    }
    return checks
  }
}

import AppKit
import Foundation
import MTVCore

extension UISmoke {
  static func systemAudioLifecycleSmoke(model: AppModel, output: URL) async -> [String: Bool] {
    guard !CommandLine.arguments.contains("--test-vlc-system-audio") else { return ["audioLifetimeUsesNormalStrategy": false] }
    for _ in 0..<400 { if !model.loading && !model.libraryRefreshing { break }; try? await Task.sleep(for: .milliseconds(25)) }
    let original = model.captureLibrarySource(), previous = model.preferredEngine
    defer { model.stopPlayback(); model.preferredEngine = previous; model.restoreLibrarySource(original); model.notice = nil; model.navigate(.home) }
    let root = SystemAudioWaveSource.ownedFixtureURL.deletingLastPathComponent().appendingPathComponent("audio-lifetime-" + UUID().uuidString, isDirectory: true)
    var checks: [String: Bool] = [:], evidence: [String: Any] = [:]
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<240 { if condition() { return }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil; config.timeoutIntervalForRequest = 5
    let session = URLSession(configuration: config)
    defer { session.invalidateAndCancel() }
    func closed(_ url: URL) async -> Bool {
      var request = URLRequest(url: url); request.timeoutInterval = 1; request.setValue("bytes=0-3", forHTTPHeaderField: "Range")
      do { _ = try await session.data(for: request); return false } catch { return true }
    }
    do {
      let aRoot = root.appendingPathComponent("A"), bRoot = root.appendingPathComponent("B")
      for folder in [aRoot, bRoot] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
      let a = aRoot.appendingPathComponent("Movie A.mp4"), b = bRoot.appendingPathComponent("Movie B.mp4")
      for file in [a, b] { try FileManager.default.copyItem(at: SystemAudioWaveSource.ownedFixtureURL, to: file) }
      let itemA = MediaItem(id: "owned-audio-lifetime-a", title: "自建结束重播", url: a.absoluteString)
      let itemB = MediaItem(id: "owned-audio-lifetime-b", title: "自建切换来源", url: b.absoluteString)
      model.useLocalRoot(aRoot)
      await wait { !model.libraryRefreshing }; await model.waitForSourceSave()
      model.preferredEngine = .vlc; model.beginPlayback(url: a, item: itemA, fromBeginning: true)
      await wait { (model.vlcEngine?.latest?.elapsed ?? 0) > 0.6 && (model.vlcEngine?.latest?.displayedPictures ?? 0) > 0 }
      guard let first = model.vlcEngine, let firstOrigin = await first.systemAudioOriginForTesting() else { throw MTVError.message("未启动实际系统音轨") }
      checks["audioLifetimeInitialNormalBridgeSelected"] = await first.systemAudioSelectedForTesting()
      first.seek(43.8)
      await wait { model.playbackCompleted || model.playbackInterruption != nil }
      checks["audioLifetimeActualEOFShowsCompletion"] = model.playbackCompleted && model.paused && first.latest?.state == 6 && model.playbackInterruption == nil
      let finished = model.resumeStore.record(for: itemA.id, source: itemA.source)
      checks["audioLifetimeEOFStoresCompletePosition"] = (finished?.position ?? 0) >= 44.9 && finished?.resumablePosition == 0
      evidence["finishedPosition"] = finished?.position ?? -1
      model.handle(.select)
      await wait { model.vlcEngine !== first && (model.vlcEngine?.latest?.elapsed ?? 0) > 0.4 && (model.vlcEngine?.latest?.displayedPictures ?? 0) > 0 }
      guard let replay = model.vlcEngine, let replayOrigin = await replay.systemAudioOriginForTesting() else { throw MTVError.message("重播未重新创建音轨服务") }
      checks["audioLifetimeRemoteReplayStartsFromBeginning"] = !model.playbackCompleted && model.localSubtitleContext?.item.id == itemA.id && (replay.latest?.elapsed ?? 100) < 3
      let replaySelected = await replay.systemAudioSelectedForTesting()
      checks["audioLifetimeReplayCreatesNewSession"] = replay !== first && replayOrigin != firstOrigin && replaySelected
      await first.waitUntilStopped()
      checks["audioLifetimeReplayClosesOldOrigin"] = await closed(firstOrigin)
      let snapshot = output.appendingPathComponent("audio-lifetime-replay.png")
      guard await replay.snapshot(to: snapshot) else { throw MTVError.message("重播没有解码画面") }
      var picture: CGImage?
      for _ in 0..<100 {
        picture = NSImage(contentsOf: snapshot)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
        if picture != nil { break }; try? await Task.sleep(for: .milliseconds(25))
      }
      guard let picture else { throw MTVError.message("重播截图未生成") }
      let frameTime = try OwnedFixtureTimecode.read(picture, rate: 30, period: 12)
      checks["audioLifetimeReplayActualFrameIsNearBeginning"] = frameTime.seconds < 3
      evidence["replayFrameTime"] = frameTime.seconds
      replay.pause(true); await wait { replay.latest?.state == 4 }
      let before = await replay.systemAudioPendingReadsForTesting() ?? 0
      let wave = try FloatAudioWave(sampleRate: 48000, channels: 1, frames: 2160000)
      var future = URLRequest(url: replayOrigin)
      let offset = wave.header.count + 40 * wave.sampleRate * wave.bytesPerFrame
      future.setValue("bytes=\(offset)-\(offset + 15)", forHTTPHeaderField: "Range")
      let pending = Task { try await session.data(for: future) }
      defer { pending.cancel() }
      for _ in 0..<100 {
        if (await replay.systemAudioPendingReadsForTesting() ?? 0) > before { break }
        try? await Task.sleep(for: .milliseconds(10))
      }
      checks["audioLifetimeOldOriginReallyHasPendingRead"] = (await replay.systemAudioPendingReadsForTesting() ?? 0) > before
      model.useLocalRoot(bRoot)
      await wait { !model.libraryRefreshing }; await model.waitForSourceSave()
      model.beginPlayback(url: b, item: itemB, fromBeginning: true)
      await wait { model.localSubtitleContext?.item.id == itemB.id && (model.vlcEngine?.latest?.elapsed ?? 0) > 0.7 && (model.vlcEngine?.latest?.displayedPictures ?? 0) > 0 }
      guard let next = model.vlcEngine, let nextOrigin = await next.systemAudioOriginForTesting() else { throw MTVError.message("新来源未启动实际音轨") }
      await replay.waitUntilStopped()
      do { _ = try await pending.value; checks["audioLifetimeSourceChangeAbortsOldHTTPRead"] = false }
      catch { checks["audioLifetimeSourceChangeAbortsOldHTTPRead"] = true }
      checks["audioLifetimeSourceChangeClosesOldService"] = await closed(replayOrigin)
      let nextSelected = await next.systemAudioSelectedForTesting()
      checks["audioLifetimeNewSourceOwnsIndependentBridge"] = nextOrigin != replayOrigin && nextSelected
      try? await Task.sleep(for: .milliseconds(250))
      checks["audioLifetimeOldCallbacksDoNotReplaceNewSource"] = model.vlcEngine === next && model.localSubtitleContext?.item.id == itemB.id && model.playbackInterruption == nil
      let handle = try FileHandle(forWritingTo: b)
      try handle.seekToEnd(); try handle.write(contentsOf: Data([0])); try handle.close()
      next.seek(6)
      await wait { model.playbackInterruption != nil }
      let rawState = await next.nativeStateForTesting()
      checks["audioLifetimeChangedPlayingFilePausesWithReason"] = model.paused && model.playbackInterruption?.contains("音轨文件") == true && (rawState == 4 || rawState == 7)
      checks["audioLifetimeReadFailureDoesNotCreateFallbackPlayer"] = model.vlcEngine === next && model.localSubtitleContext?.item.id == itemB.id && model.playbackSelectionReason.contains("系统音轨")
      evidence["failureState"] = rawState ?? -1
      model.stopPlayback(); await next.waitUntilStopped()
      checks["audioLifetimeStopAfterFailureClosesService"] = await closed(nextOrigin)
      checks["audioLifetimeStopClearsPlayback"] = model.vlcEngine == nil && !model.playbackPresented && !model.playbackCompleted
      if checks.values.allSatisfy({ $0 }) { try FileManager.default.removeItem(at: root) }
      else { evidence["keptOwnedFixtureDirectory"] = root.path }
    } catch { checks["audioLifetimeFlowCompleted"] = false; evidence["error"] = error.localizedDescription; evidence["keptOwnedFixtureDirectory"] = root.path }
    evidence["physicalAudioOutputVerified"] = false
    if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("system-audio-lifecycle.json"))
    }
    return checks
  }
}

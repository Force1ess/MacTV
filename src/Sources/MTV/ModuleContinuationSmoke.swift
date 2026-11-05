import AVFoundation
import AppKit
import MTVCore

extension UISmoke {
  static func moduleContinuationSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    guard CommandLine.arguments.contains("--live-services") else { return ["moduleContinuationLiveExplicitlyRequired": false] }
    let oldEngine = model.preferredEngine, oldAccess = model.moduleSessionAccess
    defer { model.stopPlayback(); model.preferredEngine = oldEngine; model.moduleSessionAccess = oldAccess; model.notice = nil; model.detail = nil; model.navigate(.home) }
    var checks: [String: Bool] = [:], evidence: [String: Any] = [:]
    func wait(_ condition: () -> Bool) async { for _ in 0..<450 { if condition() { return }; try? await Task.sleep(for: .milliseconds(100)) } }
    func ready(_ title: String) async -> Bool {
      var frame = false, tap: PlaybackAudioProbe?, checked = false
      await wait {
        if model.notice != nil { return true }
        if model.player?.currentItem?.status == .readyToPlay && model.elapsed > 1,
          model.playbackTitle == title, model.testDecodedFrame() != nil { frame = true; return true }
        return false
      }
      if let item = model.player?.currentItem {
        if model.smokePlaybackResolution["adapter"] as? String == "indexed-hls" {
          let sample = try? await model.smokeIndexedAudioDecode()
          checked = (sample?["frames"] ?? 0) > 0
        } else if let track = try? await item.asset.loadTracks(withMediaType: .audio).first, let probe = try? PlaybackAudioProbe() {
          probe.attach(to: item, track: track); tap = probe
          await wait { (tap?.result.frames ?? 0) > 0 || model.notice != nil }
          checked = (tap?.result.frames ?? 0) > 0
        }
      }
      var actualFrame: CGImage?
      await wait {
        if model.notice != nil { return true }
        guard model.playbackTitle == title, model.elapsed > 2, let image = model.testDecodedFrame() else { return false }
        actualFrame = image; return true
      }
      frame = actualFrame != nil && model.elapsed > 2 && model.playbackTitle == title
      if let actualFrame, let data = NSBitmapImageRep(cgImage: actualFrame).representation(using: .png, properties: [:]) {
        let name = model.moduleContinuationDiagnosticsForTesting()["currentReference"]?.replacingOccurrences(of: ":", with: "-") ?? "unknown"
        try? data.write(to: output.appendingPathComponent("decoded-" + name + ".png"))
      }
      evidence[title] = ["frame": frame, "audioPCMObserved": checked, "state": model.notice ?? model.playbackState,
        "position": model.elapsed, "resolution": model.smokePlaybackResolution, "continuation": model.moduleContinuationDiagnosticsForTesting()]
      return frame && checked
    }
    do {
      guard let plugin = model.plugins.first(where: { $0.id == "mtv.bilibili" }) else { throw MTVError.message("Bili module missing") }
      let collection = "BV1wD4y1o7AS"
      let page1 = try JSONDecoder().decode(PluginPage.self, from: await PluginClient.execute(plugin, action: "browse", input: ["folder": collection], sessionAccess: .guest))
      let page2 = try JSONDecoder().decode(PluginPage.self, from: await PluginClient.execute(plugin, action: "browse", input: ["folder": collection, "page": "2"], sessionAccess: .guest))
      let first = try PluginContentValidator.normalize(page1.items, manifest: plugin.manifest)
      let second = try PluginContentValidator.normalize(page2.items, manifest: plugin.manifest)
      guard first.count == 100, second.count == 100, let current = first.last, let target = second.first,
        let currentRef = current.reference, let last = second.last, let lastRef = last.reference else { throw MTVError.message("真实跨页选集不完整") }
      let data = try await PluginClient.execute(plugin, action: "continuation", input: ["reference": currentRef, "collection": collection], sessionAccess: .guest)
      let linked = try JSONDecoder().decode(PluginContinuation.self, from: data).validated(manifest: plugin.manifest, currentID: current.id, expectedCurrent: currentRef, expectedCollection: collection)
      checks["moduleContinuationRealSandboxCrossesP100ToP101WithoutMediaURL"] = linked.next?.reference == target.reference && linked.next?.url == nil
      let end = try JSONDecoder().decode(PluginContinuation.self, from: await PluginClient.execute(plugin, action: "continuation", input: ["reference": lastRef, "collection": collection], sessionAccess: .guest))
      checks["moduleContinuationRealLastPartIsExplicitlyNull"] = end.next == nil
      model.preferredEngine = .automatic; model.moduleSessionAccess = .guest
      model.openModule(plugin, initialDetail: current); model.handle(.select)
      checks["moduleContinuationCurrentRealP100ActuallyDecodes"] = await ready(current.title)
      checks["moduleContinuationResolveBindsCanonicalCIDAndGuestMode"] = model.moduleContinuationDiagnosticsForTesting()["currentReference"] == currentRef
        && model.moduleContinuationDiagnosticsForTesting()["sessionAccess"] == "guest" && model.nextEpisodePlan?.candidates.first?.reference == target.reference
      model.showPlayerControls()
      for _ in 0..<8 { if model.playerButton == 7 { break }; model.handle(.right) }
      model.handle(.select)
      checks["moduleContinuationRemoteNextStartsBoundedLookup"] = model.checkingModuleContinuation
      await wait { !model.checkingModuleContinuation }
      checks["moduleContinuationNextP101UsesFreshResolveAndActuallyDecodes"] = await ready(target.title)
      checks["moduleContinuationNextRemainsSameVideoAndOffersP102"] = model.detail?.reference == target.reference
        && model.moduleContinuationDiagnosticsForTesting()["collectionReference"] == collection
        && model.moduleContinuationDiagnosticsForTesting()["currentReference"] == target.reference
        && model.nextEpisodePlan?.candidates.first?.reference == second[1].reference
      await settle(); capture(window, to: output.appendingPathComponent("bilibili-p101.png"))
      model.playerButton = 7; model.handle(.select); model.handle(.back)
      try? await Task.sleep(for: .seconds(1))
      checks["moduleContinuationBackCancelsLookupWithoutChangingCurrentPart"] = !model.checkingModuleContinuation && model.detail?.reference == target.reference && model.playbackPresented
      model.playerButton = 7; model.handle(.select); model.stopPlayback()
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/PlaybackFixture.mp4")
      model.preferredEngine = .system
      model.beginPlayback(url: fixture, item: MediaItem(id: "owned-after-module-cancel", title: "Own clip after cancelled lookup", url: fixture.absoluteString))
      await wait { model.playbackTitle == "Own clip after cancelled lookup" && model.elapsed > 1 && model.testDecodedFrame() != nil }
      try? await Task.sleep(for: .seconds(1))
      checks["moduleContinuationOldLookupCannotReplaceNewPlayback"] = model.playbackTitle == "Own clip after cancelled lookup" && model.moduleContinuationDiagnosticsForTesting().isEmpty && model.nextEpisodePlan == nil
    } catch {
      checks["moduleContinuationRealFlowCompleted"] = false; evidence["error"] = error.localizedDescription
    }
    if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("module-continuation-evidence.json")) }
    return checks
  }
}

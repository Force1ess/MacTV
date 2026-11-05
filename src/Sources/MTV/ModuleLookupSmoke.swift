import AVFoundation
import AppKit
import MTVCore

extension UISmoke {
  static func moduleLookupSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    defer { model.stopPlayback(); model.notice = nil; model.detail = nil; model.keyboardVisible = false; model.navigate(.home) }
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<300 { if condition() { return }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    guard let example = model.plugins.first(where: { $0.id == "mtv.example" }) else { return ["lookupExampleInstalled": false] }
    model.openModule(example); await wait { !model.loading }
    let before = model.online.map(\.id), query = model.search
    model.focus.select(row: 1, column: model.moduleLookupColumn); model.handle(.select)
    checks["lookupRemoteToolbarOpensOwnScreenKeyboard"] = model.keyboardVisible && model.textEntryTarget == .moduleReference && !model.chinese
    model.inputText = "cancelled"; model.handle(.back)
    checks["lookupCancelPreservesExistingResultsAndQuery"] = !model.keyboardVisible && model.online.map(\.id) == before && model.search == query
    model.showModuleLookup(); model.inputText = "demo"; model.pressKey("完成")
    await wait { model.detail?.id == "lookup-demo" || model.moduleLoadFailure != nil }
    checks["lookupGenericModuleOpensNativeDetail"] = model.detail?.reference == "demo" && model.detail?.source == example.id && !model.keyboardVisible
    await settle(); capture(window, to: output.appendingPathComponent("lookup-example-detail.png"))
    model.handle(.back); model.showModuleLookup(); model.inputText = "bad"; model.pressKey("完成")
    await wait { !model.loading }
    checks["lookupErrorRetainsExactOperationForRetry"] = model.moduleLoadFailure?.action == "lookup"
      && model.moduleLoadFailure?.input["reference"] == "bad" && model.notice == nil
    model.showModuleLookup(); model.inputText = "demo"; model.pressKey("完成")
    await wait { model.detail != nil }
    checks["lookupNextRequestReplacesFailedLookup"] = model.moduleLoadFailure == nil && model.detail?.id == "lookup-demo"
    if CommandLine.arguments.contains("--live-services") {
      guard let bili = model.plugins.first(where: { $0.id == "mtv.bilibili" }) else { checks["lookupRealBilibiliPresent"] = false; return checks }
      model.openModule(bili); await wait { !model.loading }
      model.focus.select(row: 1, column: model.moduleLookupColumn); model.handle(.select)
      model.inputText = "https://www.bilibili.com/video/BV1wD4y1o7AS/?p=2&share_source=copy"
      model.pressKey("完成"); await wait { model.detail != nil || model.moduleLoadFailure != nil }
      checks["lookupRealStandardLinkSelectsSecondPart"] = model.detail?.source == bili.id
        && model.detail?.reference == "BV1wD4y1o7AS:1298431128" && model.detail?.collectionReference == "BV1wD4y1o7AS"
      await settle(); capture(window, to: output.appendingPathComponent("lookup-real-detail.png"))
      model.handle(.select)
      var frame = false, audio: PlaybackAudioProbe?
      for _ in 0..<450 {
        if model.notice != nil || model.playbackInterruption != nil { break }
        if let item = model.player?.currentItem, item.status == .readyToPlay {
          if audio == nil, let track = try? await item.asset.loadTracks(withMediaType: .audio).first,
            let probe = try? PlaybackAudioProbe() { probe.attach(to: item, track: track); audio = probe }
          if (model.player?.currentTime().seconds ?? 0) > 2, model.testDecodedFrame() != nil { frame = true; if (audio?.result.frames ?? 0) > 0 { break } }
        }
        try? await Task.sleep(for: .milliseconds(100))
      }
      checks["lookupRealSelectedPartActuallyDecodes"] = frame
      checks["lookupRealSelectedPartHasAudioPCM"] = (audio?.result.frames ?? 0) > 0
    }
    return checks
  }
}

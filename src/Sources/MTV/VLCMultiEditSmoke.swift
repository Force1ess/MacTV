import AVFoundation
import AppKit
import MTVCore
import Vision

extension UISmoke {
  static func vlcMultiEditSmoke(model: AppModel, output: URL) async -> [String: Bool] {
    let oldEngine = model.preferredEngine
    defer { model.stopPlayback(); model.preferredEngine = oldEngine; model.notice = nil; model.detail = nil; model.navigate(.home) }
    var checks: [String: Bool] = [:], evidence: [[String: Any]] = []
    for _ in 0..<400 { if !model.loading && !model.libraryRefreshing { break }; try? await Task.sleep(for: .milliseconds(50)) }
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures")
    let file = root.appendingPathComponent("ResumeChoice45-v1.mp4"), asset = AVURLAsset(url: file)
    let generator = AVAssetImageGenerator(asset: asset); generator.appliesPreferredTrackTransform = true
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    let original = AVURLAsset(url: root.appendingPathComponent("PlaybackFixture.mp4"))
    let loopDuration = (try? await original.load(.duration).seconds) ?? 0
    // The burned counter belongs to the original loop, not the exported track's
    // variable nominal rate (which includes longer boundary samples).
    let video = try? await original.loadTracks(withMediaType: .video).first
    let frameRate = (try? await video?.load(.nominalFrameRate)).map(Double.init) ?? 0
    guard loopDuration > 0, frameRate > 0 else { return ["multiEditOwnedSourceDurationKnown": false] }
    for (index, target) in [6.0, 11.5, 12.0, 12.5, 24.0, 25.5].enumerated() {
      do {
        model.stopPlayback(); model.notice = nil; model.preferredEngine = .vlc; model.navigate(.library)
        let item = MediaItem(id: "owned-multi-edit-verification", title: "自建多段编辑续播验证", url: file.absoluteString)
        model.resumeStore.save(target, for: item.id, duration: 45); model.selectContent(item); model.handle(.select)
        for _ in 0..<180 {
          if let stats = model.vlcEngine?.latest, stats.displayedPictures > 0, stats.elapsed >= target + 0.15 { break }
          if model.notice != nil || model.playbackInterruption != nil { break }
          try? await Task.sleep(for: .milliseconds(100))
        }
        guard let engine = model.vlcEngine else { throw MTVError.message("未启动原VLC引擎") }
        engine.pause(true)
        for _ in 0..<40 { if engine.latest?.state == 4 { break }; try? await Task.sleep(for: .milliseconds(100)) }
        let clock = engine.latest?.elapsed ?? -100
        checks["multiEdit-\(index)-defaultPlanUsesParsedTimeline"] = engine.containerPlan.reader == .avformat && engine.containerPlan.editSegmentCount == 4
        checks["multiEdit-\(index)-clockNearRequestedWithoutFallback"] = abs(clock - target) <= 1 && model.playbackInterruption == nil && model.player == nil
        checks["multiEdit-\(index)-audioDecodedAndSubtitlesOff"] = (engine.latest?.decodedAudio ?? 0) > 0 && (engine.latest?.subtitleID ?? -100) == -1
        let snapshot = output.appendingPathComponent("edited-\(index)-vlc.png")
        guard await engine.snapshot(to: snapshot) else { throw MTVError.message("未能请求实际视频截图") }
        var image: CGImage?
        for _ in 0..<100 {
          image = NSImage(contentsOf: snapshot)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
          if image != nil { break }; try? await Task.sleep(for: .milliseconds(50))
        }
        guard let image else { throw MTVError.message("未得到视频截图") }
        let reference = try await generator.image(at: CMTime(seconds: clock, preferredTimescale: 60_000))
        if let data = NSBitmapImageRep(cgImage: reference.image).representation(using: .png, properties: [:]) { try data.write(to: output.appendingPathComponent("edited-\(index)-reference.png")) }
        let observedRead = try OwnedFixtureTimecode.read(image, rate: frameRate, period: loopDuration), expectedRead = try OwnedFixtureTimecode.read(reference.image, rate: frameRate, period: loopDuration)
        let observed = observedRead.seconds, expected = expectedRead.seconds
        let difference = abs(observed - expected).truncatingRemainder(dividingBy: loopDuration)
        let wrappedDifference = min(difference, loopDuration - difference)
        checks["multiEdit-\(index)-actualBurnedTimeMatchesReference"] = wrappedDifference < 0.8
        model.stopPlayback()
        let saved = model.resumeStore.position(for: item.id)
        checks["multiEdit-\(index)-savedPositionUsesActualClock"] = abs(saved - clock) < 0.3
        evidence.append(["target": target, "vlcClock": clock, "vlcPictureTime": observed, "referencePictureTime": expected,
          "observedMethod": observedRead.method, "referenceMethod": expectedRead.method, "frameRate": frameRate,
          "referenceActualTime": reference.actualTime.seconds, "loopDuration": loopDuration, "pictureDifference": wrappedDifference, "saved": saved])
      } catch { checks["multiEdit-\(index)-completed"] = false; evidence.append(["target": target, "error": error.localizedDescription]) }
      if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("multi-edit-verification.json")) }
    }
    return checks
  }
}

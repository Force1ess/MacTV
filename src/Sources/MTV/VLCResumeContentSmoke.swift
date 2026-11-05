import AVFoundation
import AppKit
import MTVCore

extension UISmoke {
  static func vlcResumeContentSmoke(model: AppModel, output: URL) async -> [String: Bool] {
    let oldEngine = model.preferredEngine
    defer { model.stopPlayback(); model.preferredEngine = oldEngine; model.notice = nil; model.detail = nil; model.navigate(.home) }
    var checks: [String: Bool] = [:], samples: [[String: Any]] = []
    func pixels(_ image: CGImage) -> [UInt8]? {
      var bytes = [UInt8](repeating: 0, count: 64 * 36 * 4)
      let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let context = CGContext(data: buffer.baseAddress, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 256,
          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
        context.interpolationQuality = .medium; context.draw(image, in: CGRect(x: 0, y: 0, width: 64, height: 36)); return true
      }
      return drawn ? bytes : nil
    }
    func difference(_ first: [UInt8], _ second: [UInt8]) -> Double {
      var total = 0.0
      for index in first.indices where index % 4 != 3 { total += abs(Double(first[index]) - Double(second[index])) }
      return total / Double(64 * 36 * 3 * 255)
    }
    func write(_ image: CGImage, _ name: String) throws {
      guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
      try data.write(to: output.appendingPathComponent(name))
    }
    for _ in 0..<400 { if !model.loading && !model.libraryRefreshing { break }; try? await Task.sleep(for: .milliseconds(50)) }
    for name in ["ResumeChoice45-v1.mp4", "IndependentLongGOP45-v1.mp4"] {
      do {
        model.stopPlayback(); model.notice = nil; model.preferredEngine = .vlc; model.navigate(.library)
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/" + name)
        let item = MediaItem(id: "resume-content-owned-" + name, title: name, url: file.absoluteString)
        model.resumeStore.save(12, for: item.id, duration: 45); model.selectContent(item); model.handle(.select)
        for _ in 0..<200 {
          if let stats = model.vlcEngine?.latest, stats.displayedPictures > 0, stats.elapsed > 10 { break }
          if model.notice != nil { break }; try? await Task.sleep(for: .milliseconds(100))
        }
        guard let engine = model.vlcEngine else { throw MTVError.message("未启动VLC") }
        engine.pause(true)
        for _ in 0..<50 { if engine.latest?.state == 4 { break }; try? await Task.sleep(for: .milliseconds(100)) }
        let clock = engine.latest?.elapsed ?? -1
        let planned = engine.containerPlan
        let overridden = CommandLine.arguments.contains("--test-vlc-avformat") || CommandLine.arguments.contains("--test-vlc-native-reader")
        checks[name + "-timelineReaderClassified"] = planned.reader == (name == "ResumeChoice45-v1.mp4" ? .avformat : .native)
          && planned.editSegmentCount == (name == "ResumeChoice45-v1.mp4" ? 4 : 1)
        if !overridden { checks[name + "-defaultResumeClockNearRequested"] = abs(clock - 12) <= 1 && model.playbackInterruption == nil }
        let path = output.appendingPathComponent(name + "-vlc.png")
        let requested = await engine.snapshot(to: path)
        var actual: CGImage?
        for _ in 0..<100 {
          if let image = NSImage(contentsOf: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil) { actual = image; break }
          try? await Task.sleep(for: .milliseconds(50))
        }
        guard let actual, let targetPixels = pixels(actual), clock > 0 else { throw MTVError.message("未取得实际VLC视频截图") }
        checks[name + "-actualVLCFrameCaptured"] = requested
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file)); generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 320, height: 180)
        var candidates: [[String: Any]] = []
        let times = Array(stride(from: 0.0, through: 44.5, by: 0.5)) + [12, clock]
        for second in times {
          guard let frame = try? await generator.image(at: CMTime(seconds: second, preferredTimescale: 60_000)), let buffer = pixels(frame.image) else { continue }
          let score = difference(targetPixels, buffer)
          candidates.append(["requestedTime": second, "actualTime": frame.actualTime.seconds, "rgbMeanAbsoluteError": score])
          if second == 12 { try write(frame.image, name + "-reference-requested.png") }
          if second == clock { try write(frame.image, name + "-reference-clock.png") }
        }
        candidates.sort { ($0["rgbMeanAbsoluteError"] as! Double) < ($1["rgbMeanAbsoluteError"] as! Double) }
        checks[name + "-referenceFramesCompared"] = candidates.count >= 80
        checks[name + "-clockRemainedPausedDuringComparison"] = abs((engine.latest?.elapsed ?? -100) - clock) < 0.2
        let protected = model.playbackInterruption != nil
        model.stopPlayback()
        if name == "ResumeChoice45-v1.mp4" { checks["editedMismatchCannotOverwriteOldProgress"] = abs(clock - 12) <= 2 || (protected && model.resumeStore.position(for: item.id) == 12) }
        samples.append(["sample": name, "requestedResume": 12, "vlcClock": clock, "pausedOnMismatch": protected,
          "containerReader": CommandLine.arguments.contains("--test-vlc-native-reader") ? "native-diagnostic" : (CommandLine.arguments.contains("--test-vlc-avformat") ? "avformat-diagnostic" : String(describing: planned.reader)),
          "plannedReader": String(describing: planned.reader), "editSegments": planned.editSegmentCount ?? -1,
          "bestFrameCandidates": Array(candidates.prefix(12)), "requestedFrame": candidates.first { ($0["requestedTime"] as? Double) == 12 } ?? [:],
          "clockFrame": candidates.first { ($0["requestedTime"] as? Double) == clock } ?? [:],
          "editedAccurateResumeVerified": false])
      } catch {
        checks[name + "-diagnosticCompleted"] = false
        samples.append(["sample": name, "error": error.localizedDescription])
      }
      if let data = try? JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("resume-content-comparison.json")) }
    }
    return checks
  }
}

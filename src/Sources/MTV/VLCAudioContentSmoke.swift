import AVFoundation
import AppKit
import MTVCore

extension UISmoke {
  static func vlcAudioContentSmoke(model: AppModel, output: URL) async -> [String: Bool] {
    guard CommandLine.arguments.contains("--test-vlc-audio-content") else { return ["audioContentExplicitCaptureRequired": false] }
    let oldEngine = model.preferredEngine
    defer { model.stopPlayback(); model.preferredEngine = oldEngine; model.notice = nil; model.detail = nil; model.navigate(.home) }
    var checks: [String: Bool] = [:], evidence: [[String: Any]] = []
    for _ in 0..<400 { if !model.loading && !model.libraryRefreshing { break }; try? await Task.sleep(for: .milliseconds(50)) }
    let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/AudioTimeline-v1/Edited-Audio-Timeline45.mp4")
    for (index, target) in [6.0, 11.5, 12.5, 23.5, 24.5, 25.5].enumerated() {
      do {
        model.stopPlayback(); model.preferredEngine = .vlc; model.navigate(.library)
        let item = MediaItem(id: "owned-audio-content-timeline", title: "自建音视频时间线", url: file.absoluteString)
        model.resumeStore.save(target, for: item.id, duration: 45); model.selectContent(item); model.handle(.select)
        for _ in 0..<180 {
          if let value = model.vlcEngine?.latest, value.elapsed >= target + 1, value.displayedPictures > 0 { break }
          if model.notice != nil || model.playbackInterruption != nil { break }
          try? await Task.sleep(for: .milliseconds(100))
        }
        guard let engine = model.vlcEngine else { throw MTVError.message("未启动实际VLC") }
        let capture = await engine.audioContentForTesting()
        if CommandLine.arguments.contains("--test-vlc-system-audio") {
          checks["audioContent-\(index)-systemAudioBridgeActuallySelected"] = capture["systemAudioBridgeSelected"] as? Bool == true
        }
        guard let mediaTime = capture["mediaTime"] as? Double, let clock = capture["clockMicroseconds"] as? Int64,
          let blocks = capture["blocks"] as? [[String: Any]] else { throw MTVError.message("未收到音频采集数据") }
        let near = blocks.compactMap { row -> [String: Any]? in
          guard let pts = row["ptsMicroseconds"] as? Int64, let frequency = row["frequencyHz"] as? Double,
            let rms = row["rms"] as? Double, rms > 0.01, frequency > 100 else { return nil }
          let delay = Double(pts - clock) / 1_000_000
          guard abs(delay) < 0.5 else { return nil }
          let scheduledMediaTime = mediaTime + delay
          let inferredContentTime = (frequency - 400) / 25
          return ["pts": pts, "frequencyHz": frequency, "rms": rms, "scheduleDelay": delay,
            "scheduledMediaTime": scheduledMediaTime, "inferredContentTime": inferredContentTime,
            "contentTimeDifference": inferredContentTime - scheduledMediaTime]
        }
        checks["audioContent-\(index)-decodedPCMObserved"] = !blocks.isEmpty && blocks.contains { ($0["rms"] as? Double ?? 0) > 0.01 }
        checks["audioContent-\(index)-scheduledBlocksNearCurrentClock"] = !near.isEmpty
        checks["audioContent-\(index)-videoStillDecodesAtResume"] = abs((engine.latest?.elapsed ?? -100) - target) < 2.5 && (engine.latest?.displayedPictures ?? 0) > 0 && model.playbackInterruption == nil
        checks["audioContent-\(index)-multisegmentPlanPreserved"] = engine.containerPlan.reader == .avformat && (engine.containerPlan.editSegmentCount ?? 0) > 1
        engine.pause(true)
        for _ in 0..<40 { if engine.latest?.state == 4 { break }; try? await Task.sleep(for: .milliseconds(50)) }
        let pausedCapture = await engine.audioContentForTesting()
        let pausePTS = pausedCapture["pausePTS"] as? Int64 ?? 0
        let pausedRows = pausedCapture["blocks"] as? [[String: Any]] ?? []
        let nearest = pausedRows.filter { ($0["rms"] as? Double ?? 0) > 0.01 }.min {
          abs(($0["ptsMicroseconds"] as? Int64 ?? 0) - pausePTS) < abs(($1["ptsMicroseconds"] as? Int64 ?? 0) - pausePTS)
        }
        let frame = output.appendingPathComponent("audio-content-\(index)-video.png")
        guard await engine.snapshot(to: frame) else { throw MTVError.message("未请求到实际视频画面") }
        var picture: CGImage?
        for _ in 0..<100 {
          picture = NSImage(contentsOf: frame)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
          if picture != nil { break }; try? await Task.sleep(for: .milliseconds(50))
        }
        guard let picture else { throw MTVError.message("实际视频截图未生成") }
        let pictureTime = try OwnedFixtureTimecode.read(picture, rate: 30, period: 12)
        let pausedClock = pausedCapture["mediaTime"] as? Double ?? -100
        let videoCandidates: [Double] = (0..<4).map { pictureTime.seconds + Double($0) * 12.0 }
        let videoTime: Double = videoCandidates.min(by: { abs($0 - pausedClock) < abs($1 - pausedClock) }) ?? -100
        var audioAtPause: Double = -100, ptsDistance: Double = -100
        if let nearest, let frequency = nearest["frequencyHz"] as? Double, let pts = nearest["ptsMicroseconds"] as? Int64 {
          ptsDistance = Double(pausePTS - pts) / 1_000_000
          audioAtPause = (frequency - 400) / 25 + ptsDistance
        }
        checks["audioContent-\(index)-audioPauseTimestampAndVideoObserved"] = pausePTS > 0 && nearest != nil && abs(ptsDistance) < 0.2
        checks["audioContent-\(index)-decodedAudioAndVideoContentAligned"] = abs(audioAtPause - videoTime) < 0.1
        let voiced = blocks.filter { ($0["rms"] as? Double ?? 0) > 0.01 && ($0["frequencyHz"] as? Double ?? 0) > 100 }
        let steps: [Double] = zip(voiced, voiced.dropFirst()).compactMap { first, second in
          guard let a = first["frequencyHz"] as? Double, let b = second["frequencyHz"] as? Double,
            let p = first["ptsMicroseconds"] as? Int64, let q = second["ptsMicroseconds"] as? Int64 else { return nil }
          return (b - a) / 25 - Double(q - p) / 1_000_000
        }
        checks["audioContent-\(index)-noEditBoundaryAudioContentJump"] = steps.count > 10 && steps.allSatisfy { abs($0) < 0.1 }
        evidence.append(["target": target, "mediaTime": mediaTime, "libVLCClock": clock, "capturedBlockCount": blocks.count,
          "nearScheduledBlocks": near, "allBlocks": blocks, "physicalAudioOutputVerified": false,
          "pausedCapture": pausedCapture, "videoBurnedTime": pictureTime.seconds, "videoContentTime": videoTime,
          "audioContentTimeAtPause": audioAtPause, "audioVideoContentDifference": audioAtPause - videoTime, "pauseSampleDistance": ptsDistance,
          "audioContentStepErrors": steps])
      } catch { checks["audioContent-\(index)-captureCompleted"] = false; evidence.append(["target": target, "error": error.localizedDescription]) }
      if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: output.appendingPathComponent("audio-content-evidence.json")) }
    }
    return checks
  }
}

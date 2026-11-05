import AppKit
import Foundation
import MTVCore
import Vision

extension UISmoke {
  static func systemAudioSessionSmoke(model: AppModel, output: URL,
    file: URL = SystemAudioWaveSource.ownedFixtureURL, requiresInternalFlag: Bool = true) async -> [String: Bool] {
    guard (!requiresInternalFlag || CommandLine.arguments.contains("--test-vlc-system-audio")), CommandLine.arguments.contains("--test-vlc-audio-content") else {
      return ["systemAudioSessionRequiresExplicitOwnedAudioSink": false]
    }
    let previous = model.preferredEngine
    defer { model.stopPlayback(); model.preferredEngine = previous; model.notice = nil; model.detail = nil; model.navigate(.home) }
    var checks: [String: Bool] = [:], measurements: [[String: Any]] = []
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<160 { if condition() { return }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    do {
      let root = file.deletingLastPathComponent()
      let sidecar = file.deletingPathExtension().appendingPathExtension("mtv-session-" + UUID().uuidString + ".srt")
      let caption = "MTV BRIDGE CAPTION"
      try Data("1\n00:00:00,000 --> 00:00:44,900\n\(caption)\n".utf8).write(to: sidecar, options: .withoutOverwriting)
      defer { try? FileManager.default.removeItem(at: sidecar) }
      let reader = LocalSubtitleReader(), access = ScopedFileAccess.within(root)
      let listing = try await reader.discover(for: file, access: access)
      guard let candidate = listing.candidates.first(where: { $0.url == sidecar }) else { throw MTVError.message("未发现自建字幕") }
      let prepared = try await reader.prepare(candidate, access: access)
      model.preferredEngine = .vlc
      model.beginPlayback(url: file, item: MediaItem(id: "owned-system-audio-session", title: "自建系统音轨与字幕", url: file.absoluteString),
        subtitleRestart: SubtitlePlaybackRestart(subtitle: prepared, position: 11.5, paused: false))
      await wait { (model.vlcEngine?.latest?.elapsed ?? 0) > 12.7 || model.playbackInterruption != nil }
      guard let engine = model.vlcEngine else { throw MTVError.message("未启动真实VLC") }
      checks["systemSessionStartsWithPreparedCaption"] = engine.subtitle === prepared && (engine.latest?.displayedPictures ?? 0) > 0 && model.playbackInterruption == nil
      let origin = await engine.systemAudioOriginForTesting()
      checks["systemSessionOwnsSeparateOrigin"] = origin?.host == "127.0.0.1"
      let audioMenu = await engine.tracks(subtitles: false)
      checks["systemSessionSingleReplacementAudioOption"] = audioMenu.options.count == 1
        && audioMenu.options.first?.trackID == audioMenu.selectedID
      // The generated movie's original audio ES is 0; the selected slave ID is
      // discovered at runtime. Hidden original audio cannot be selected again.
      checks["systemSessionHiddenOriginalAudioCannotBeSelected"] = !(await engine.selectTrack(subtitles: false, id: 0))
      if !requiresInternalFlag {
        checks["systemSessionNormalPathWithoutForceFlag"] = !CommandLine.arguments.contains("--test-vlc-system-audio")
          && model.playbackSelectionReason.contains("系统音轨") && !model.playbackSelectionReason.contains("可能短暂异常")
      }
      for (index, target) in [11.5, 23.5, 11.5].enumerated() {
        let priorFrames = engine.latest?.displayedPictures ?? 0
        engine.seek(target); engine.pause(false)
        await wait {
          guard let stats = engine.latest else { return false }
          return stats.state == 3 && stats.elapsed >= target + 1.2 && stats.elapsed < target + 3
            && stats.displayedPictures > priorFrames
        }
        checks["systemSession-\(index)-seekProducedNewVideo"] = engine.latest?.state == 3
          && (engine.latest?.elapsed ?? -1) >= target + 1.2 && (engine.latest?.elapsed ?? 100) < target + 3
          && (engine.latest?.displayedPictures ?? 0) > priorFrames
        engine.pause(true); await wait { engine.latest?.state == 4 }
        let capture = await engine.audioContentForTesting(), paused = engine.latest?.elapsed ?? -1
        checks["systemSession-\(index)-systemAudioStillSelected"] = capture["systemAudioBridgeSelected"] as? Bool == true
        let frame = output.appendingPathComponent("system-session-\(index).png")
        guard await engine.snapshot(to: frame) else { throw MTVError.message("未请求到字幕合成帧") }
        var picture: CGImage?
        for _ in 0..<100 {
          picture = NSImage(contentsOf: frame)?.cgImage(forProposedRect: nil, context: nil, hints: nil)
          if picture != nil { break }; try? await Task.sleep(for: .milliseconds(30))
        }
        guard let picture else { throw MTVError.message("未生成真实视频帧") }
        let burned = try OwnedFixtureTimecode.read(picture, rate: 30, period: 12)
        let videoCandidates: [Double] = (0..<4).map { burned.seconds + Double($0) * 12.0 }
        let video = videoCandidates.min(by: { abs($0 - paused) < abs($1 - paused) }) ?? -100
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]; request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: picture).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        checks["systemSession-\(index)-captionVisibleInDecodedFrame"] = text.uppercased().contains(caption)
        let pausePTS = capture["pausePTS"] as? Int64 ?? 0
        let blocks = capture["blocks"] as? [[String: Any]] ?? []
        let voiced = blocks.filter { ($0["rms"] as? Double ?? 0) > 0.01 && ($0["frequencyHz"] as? Double ?? 0) > 100 }
        let nearest = voiced.min { abs(($0["ptsMicroseconds"] as? Int64 ?? 0) - pausePTS) < abs(($1["ptsMicroseconds"] as? Int64 ?? 0) - pausePTS) }
        let distance = Double(pausePTS - (nearest?["ptsMicroseconds"] as? Int64 ?? 0)) / 1e6
        let audio = ((nearest?["frequencyHz"] as? Double ?? -10000) - 400) / 25 + distance
        checks["systemSession-\(index)-audioAndActualVideoContentAlign"] = pausePTS > 0 && abs(distance) < 0.2 && abs(audio - video) < 0.1
        let steps: [Double] = zip(voiced, voiced.dropFirst()).map { first, second in
          let firstFrequency: Double = first["frequencyHz"] as? Double ?? 0
          let secondFrequency: Double = second["frequencyHz"] as? Double ?? 0
          let firstPTS: Int64 = first["ptsMicroseconds"] as? Int64 ?? 0
          let secondPTS: Int64 = second["ptsMicroseconds"] as? Int64 ?? 0
          let frequencySeconds: Double = (secondFrequency - firstFrequency) / 25
          let timestampSeconds: Double = Double(secondPTS - firstPTS) / 1e6
          return frequencySeconds - timestampSeconds
        }
        checks["systemSession-\(index)-audioContinuityAfterSeek"] = steps.count > 10 && steps.allSatisfy { abs($0) < 0.1 }
        try? await Task.sleep(for: .milliseconds(300))
        let still = await engine.statisticsForTesting()
        checks["systemSession-\(index)-pauseHoldsClock"] = still?.state == 4 && abs((still?.elapsed ?? -100) - paused) < 0.03
        engine.pause(false)
        await wait { engine.latest?.state == 3 && (engine.latest?.elapsed ?? 0) > paused + 0.3 }
        checks["systemSession-\(index)-resumeAdvancesClock"] = engine.latest?.state == 3 && (engine.latest?.elapsed ?? 0) > paused + 0.3
        measurements.append(["target": target, "pausedClock": paused, "videoContentTime": video,
          "audioContentTime": audio, "ocr": text, "audioStepErrors": steps,
          "physicalAudioOutputVerified": false])
      }
      model.stopPlayback(); await engine.waitUntilStopped()
      if let origin {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 2
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        do { _ = try await session.data(from: origin); checks["systemSessionStopClosesOrigin"] = false }
        catch { checks["systemSessionStopClosesOrigin"] = true }
      }
      checks["systemSessionStopClearsPlayer"] = model.vlcEngine == nil && !model.playbackPresented
    } catch { checks["systemSessionFlowCompleted"] = false; measurements.append(["error": error.localizedDescription]) }
    if let data = try? JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("system-audio-session.json"))
    }
    return checks
  }
}

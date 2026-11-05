import AVFoundation
import Foundation
import MTVCore

extension UISmoke {
  static func splitPlaybackSmoke(model: AppModel, output: URL) async -> [String: Bool] {
    guard let index = CommandLine.arguments.firstIndex(of: "--test-http-port"), index + 1 < CommandLine.arguments.count,
      let port = Int(CommandLine.arguments[index + 1]), (1024...65535).contains(port) else { return [:] }
    let original = model.preferredEngine
    defer { model.stopPlayback(); model.preferredEngine = original; model.notice = nil }
    model.preferredEngine = .system
    var checks: [String: Bool] = [:]
    var diagnostics: [String: Any] = ["fixtureOnly": true, "physicalAudioOutputVerified": false, "physicalAVSyncVerified": false]
    func request(_ path: String) throws -> RemotePlaybackRequest {
      try RemotePlaybackRequest.testingLoopback(url: URL(string: "http://127.0.0.1:\(port)/mtv-fixture/" + path)!,
        headers: ["User-Agent": "MTV-HeaderFixture/1", "Referer": "https://fixture.invalid/"], referer: "https://fixture.invalid/")
    }
    func ready() async {
      for _ in 0..<400 {
        if !model.preparingPlayback { break }
        try? await Task.sleep(for: .milliseconds(40))
      }
    }
    func stats() async throws -> [String: Any] {
      let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/stats")!)
      guard (response as? HTTPURLResponse)?.statusCode == 200,
        let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MTVError.message("分轨测试统计不可用") }
      return value
    }
    do {
      let video = try request("split-video.mp4"), audio = try request("split-audio.m4a")
      model.beginRemotePlayback(video: video, audio: audio, item: MediaItem(id: "split-http-fixture", title: "Generated separate tracks"))
      await ready()
      guard let player = model.player, let item = player.currentItem else { throw MTVError.message(model.notice ?? "没有建立原生分轨播放器") }
      let videoTracks = try await item.asset.loadTracks(withMediaType: .video)
      let audioTracks = try await item.asset.loadTracks(withMediaType: .audio)
      checks["splitCompositionHasOneVideoAndOneAudio"] = videoTracks.count == 1 && audioTracks.count == 1 && item.asset is AVComposition
      let probe = try PlaybackAudioProbe()
      if let track = audioTracks.first { probe.attach(to: item, track: track) }
      var decoded = false
      for _ in 0..<200 {
        if model.testDecodedFrame() != nil { decoded = true }
        if decoded && probe.result.nonzero > 0 { break }
        if item.status == .failed { break }
        try? await Task.sleep(for: .milliseconds(30))
      }
      checks["splitVideoActuallyDecoded"] = decoded && item.status == .readyToPlay
      checks["splitAudioActuallyDecodedPCM"] = probe.result.frames > 0 && probe.result.float32 && probe.result.nonzero > 0
      diagnostics["audioFrames"] = probe.result.frames; diagnostics["audioNonzeroSamples"] = probe.result.nonzero
      let before = try await stats()
      let countBefore = (before["requests"] as? [[String: Any]])?.count ?? 0
      let started = Date()
      let seeked = await player.seek(to: CMTime(seconds: 35, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
      var afterSeekFrame = false
      for _ in 0..<200 {
        if player.currentTime().seconds >= 34.8, model.testDecodedFrame() != nil { afterSeekFrame = true; break }
        try? await Task.sleep(for: .milliseconds(30))
      }
      checks["splitSeekRetainsResourcesAndDecodes"] = seeked && afterSeekFrame && Date().timeIntervalSince(started) < 12
      diagnostics["seekWallSeconds"] = Date().timeIntervalSince(started); diagnostics["seekObservedSeconds"] = player.currentTime().seconds
      let after = try await stats()
      let extra = Array(((after["requests"] as? [[String: Any]]) ?? []).dropFirst(countBefore))
      checks["splitSeekFetchedAdditionalRemoteVideoRange"] = extra.contains { record in
        guard (record["path"] as? String)?.hasPrefix("/mtv-fixture/split-video.mp4") == true,
          let range = record["range"] as? String,
          let offset = Int64(range.dropFirst(6).split(separator: "-").first ?? "") else { return false }
        return offset > 4_000_000 && offset < 15_000_000
      }
      diagnostics["serverAfterSeek"] = after
      model.stopPlayback(); model.notice = nil
      model.beginRemotePlayback(video: video, audio: try request("short-audio.m4a"), item: MediaItem(id: "split-short-audio", title: "Generated mismatched timeline"))
      await ready()
      checks["splitRejectsMismatchedDurationWithoutTrimming"] = model.player == nil && model.notice?.contains("时间范围") == true
      diagnostics["mismatchedTimelineNotice"] = model.notice ?? ""
      model.stopPlayback(); model.notice = nil
      model.beginRemotePlayback(video: video, audio: video, item: MediaItem(id: "split-missing-audio", title: "Generated missing audio"))
      await ready()
      checks["splitRejectsMissingAudioRatherThanPlayingSilently"] = model.player == nil && model.notice?.contains("缺少") == true
      model.stopPlayback(); model.notice = nil
      model.beginRemotePlayback(video: video, audio: try request("slow.mp4"), item: MediaItem(id: "split-cancelled", title: "Generated cancelled preparation"))
      try? await Task.sleep(for: .milliseconds(800))
      model.handle(.back)
      checks["splitBackCancelsBothPreparingResources"] = !model.preparingPlayback && model.player == nil
      let final = try await stats()
      diagnostics["serverFinal"] = final
      checks["splitCredentialsNeverSentAndAllHeadersMatch"] = final["cookieRequests"] as? Int == 0
        && final["authorizationRequests"] as? Int == 0 && final["missingHeaders"] as? Int == 0
    } catch { checks["splitPlaybackFixtureFlow"] = false; diagnostics["error"] = error.localizedDescription }
    if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("split-playback.json"), options: .atomic)
    }
    return checks
  }
}

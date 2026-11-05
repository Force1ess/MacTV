import AVFoundation
import AppKit
import MTVCore

extension UISmoke {
  static func remoteHeaderSmoke(model: AppModel, output: URL) async -> [String: Bool] {
    guard let index = CommandLine.arguments.firstIndex(of: "--test-http-port"), index + 1 < CommandLine.arguments.count,
      let port = Int(CommandLine.arguments[index + 1]), (1024...65535).contains(port) else { return [:] }
    let oldEngine = model.preferredEngine
    defer { model.stopPlayback(); model.preferredEngine = oldEngine; model.notice = nil }
    model.preferredEngine = .system
    var checks: [String: Bool] = [:]
    var diagnostics: [String: Any] = ["fixtureOnly": true, "realPlatformPlaybackVerified": false]
    func plan(_ name: String) throws -> RemotePlaybackRequest {
      try RemotePlaybackRequest.testingLoopback(url: URL(string: "http://127.0.0.1:\(port)/mtv-fixture/\(name).mp4" + (["changed", "clock"].contains(name) ? "?session=" + UUID().uuidString : ""))!,
        headers: ["Referer": "https://fixture.invalid/", "User-Agent": "MTV-HeaderFixture/1"], referer: "https://fixture.invalid/")
    }
    func awaitPreparation() async {
      for _ in 0..<160 {
        if !model.preparingPlayback { break }
        try? await Task.sleep(for: .milliseconds(40))
      }
    }
    do {
      if !CommandLine.arguments.contains("--test-isolated-header-session") {
        func poolPorts() async throws -> [Int] {
          let (data, _) = try await URLSession.shared.data(from: URL(string:"http://127.0.0.1:\(port)/stats")!)
          return (try JSONSerialization.jsonObject(with:data) as? [String:Any])?["poolClientPorts"] as? [Int] ?? []
        }
        func drain(_ stream: RemoteHeaderStream) async {
          for _ in 0..<100 {
            if (await stream.statistics())["activeJobs"] == 0 { return }
            try? await Task.sleep(for: .milliseconds(20))
          }
        }
        let first = try RemoteHeaderStream(plan("pool"))
        _ = try await first.asset.load(.isPlayable); await drain(first)
        let before = try await poolPorts()
        first.cancel(); _ = await first.statistics()
        let second = try RemoteHeaderStream(plan("pool"))
        defer { second.cancel() }
        checks["remoteHeaderNextOwnerSurvivesPreviousCancellation"] = try await second.asset.load(.isPlayable)
        await drain(second)
        let after = try await poolPorts()
        checks["remoteHeaderSequentialOwnersReuseActualConnection"] = !Set(before).intersection(Set(after.dropFirst(before.count))).isEmpty
      }
      let request = try plan("redirect")
      model.beginHeaderPlayback(request: request, item: MediaItem(id: "http-header-fixture", title: "Generated HTTP fixture"))
      await awaitPreparation()
      var decoded = false
      for _ in 0..<120 {
        if model.player?.currentItem?.status == .readyToPlay && model.testDecodedFrame() != nil { decoded = true; break }
        try? await Task.sleep(for: .milliseconds(40))
      }
      checks["remoteHeaderActualNativeFrameDecoded"] = model.player?.currentItem?.status == .readyToPlay && decoded
      if let player = model.player {
        let duration = player.currentItem?.duration.seconds ?? 0
        guard duration.isFinite, duration > 2 else { throw MTVError.message("Owned HTTP fixture duration is unavailable") }
        let target = min(20, max(1, duration * 0.6))
        diagnostics["fixtureDurationSeconds"] = duration
        diagnostics["seekTargetSeconds"] = target
        let started = Date()
        let seeked = await player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        var seekDecoded = false
        for _ in 0..<100 {
          if abs(player.currentTime().seconds - target) < 0.75,
            let observation = model.smokeDecodedFrameObservation(), let time = observation.presentationTime,
            abs(time - target) < 0.75 { seekDecoded = true; diagnostics["seekFramePresentationSeconds"] = time; break }
          try? await Task.sleep(for: .milliseconds(30))
        }
        checks["remoteHeaderSeekDecodesRequestedPosition"] = seeked && abs(player.currentTime().seconds - target) < 0.75
          && seekDecoded && Date().timeIntervalSince(started) < 10
        diagnostics["seekObservedSeconds"] = player.currentTime().seconds
        diagnostics["seekWallSeconds"] = Date().timeIntervalSince(started)
      } else { checks["remoteHeaderSeekDecodesRequestedPosition"] = false }
      model.stopPlayback(); model.notice = nil
      model.beginHeaderPlayback(request: try plan("slow-tail"), item: MediaItem(id: "http-progressive-tail", title: "Generated delayed range tail"))
      await awaitPreparation()
      var beforeTail = false, progressiveDelivered = false
      for _ in 0..<140 {
        if model.testDecodedFrame() != nil {
          let statistics = await model.smokeRemoteStatistics()
          progressiveDelivered = (statistics["video.progressiveDeliveries"] ?? 0) > 0
          if let (data, _) = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/stats")!),
            let state = try? JSONSerialization.jsonObject(with:data) as? [String:Any] {
            beforeTail = (state["slowTailStarted"] as? Int ?? 0) > 0 && (state["slowTailCompleted"] as? Int ?? 0) == 0
          }
          break
        }
        if model.notice != nil { break }
        try? await Task.sleep(for: .milliseconds(40))
      }
      checks["remoteHeaderDeliversValidatedPartialRangeToAVFoundation"] = progressiveDelivered
      checks["remoteHeaderActualFramePrecedesDelayedRangeTail"] = beforeTail
      model.stopPlayback(); model.notice = nil
      model.beginHeaderPlayback(request: try plan("minimal"), item: MediaItem(id: "http-minimal-headers", title: "Generated conditional response"))
      await awaitPreparation()
      var minimalDecoded = false
      for _ in 0..<120 {
        if model.testDecodedFrame() != nil { minimalDecoded = true; break }
        if model.notice != nil { break }
        try? await Task.sleep(for: .milliseconds(40))
      }
      checks["remoteHeaderConditionalResponsesMayOmitRepeatedMetadata"] = minimalDecoded
      model.stopPlayback(); model.notice = nil
      model.beginHeaderPlayback(request: try plan("clock"), item: MediaItem(id: "http-weak-clock", title: "Generated varying weak timestamp"))
      await awaitPreparation()
      var clockDecoded = false
      for _ in 0..<120 {
        if model.testDecodedFrame() != nil { clockDecoded = true; break }
        if model.notice != nil { break }
        try? await Task.sleep(for: .milliseconds(40))
      }
      checks["remoteHeaderWeakClockChangeIsNotFalseContentChange"] = clockDecoded
      model.stopPlayback(); model.notice = nil
      for name in ["escape", "bad-range", "changed", "truncated"] {
        model.beginHeaderPlayback(request: try plan(name), item: MediaItem(id: "http-failure-" + name, title: "Generated rejected response"))
        await awaitPreparation()
        checks["remoteHeaderRejects-\(name)"] = model.player == nil && !model.preparingPlayback && model.notice != nil
        model.stopPlayback(); model.notice = nil
      }
      model.beginHeaderPlayback(request: try plan("slow"), item: MediaItem(id: "http-slow-fixture", title: "Generated slow response"))
      try? await Task.sleep(for: .milliseconds(350))
      let cancelledAt = Date()
      model.handle(.back)
      checks["remoteHeaderBackCancelsPreparationImmediately"] = !model.preparingPlayback && model.player == nil
        && Date().timeIntervalSince(cancelledAt) < 1
      let local = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/PlaybackFixture.mp4")
      model.beginPlayback(url: local, item: MediaItem(id: "http-replacement-fixture", title: "Replacement after cancelled HTTP", url: local.absoluteString))
      await awaitPreparation()
      var replacementDecoded = false
      for _ in 0..<100 {
        if model.testDecodedFrame() != nil { replacementDecoded = true; break }
        try? await Task.sleep(for: .milliseconds(30))
      }
      checks["remoteHeaderCancelledRequestCannotReplaceNewPlayback"] = replacementDecoded
        && model.playbackTitle == "Replacement after cancelled HTTP"
      model.stopPlayback()
      let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/stats")!)
      guard (response as? HTTPURLResponse)?.statusCode == 200,
        let stats = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw MTVError.message("测试服务器未返回统计") }
      diagnostics["server"] = stats
      checks["remoteHeaderConditionalOmissionWasExercised"] = (stats["minimalHeaderResponses"] as? Int ?? 0) > 0
      checks["remoteHeaderWeakClockVariationWasExercised"] = (stats["weakClockResponses"] as? Int ?? 0) > 1
      checks["remoteHeaderRedirectOutsideOriginNeverFetched"] = stats["foreignRequests"] as? Int == 0
      checks["remoteHeaderAllRequestsHaveReviewedHeaders"] = (stats["mediaRequests"] as? Int ?? 0) > 2 && stats["missingHeaders"] as? Int == 0
      checks["remoteHeaderSetCookieNeverReplayed"] = stats["cookieRequests"] as? Int == 0 && stats["authorizationRequests"] as? Int == 0
    } catch {
      checks["remoteHeaderFixtureFlow"] = false
      diagnostics["failure"] = error.localizedDescription
    }
    if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("remote-header-stream.json"), options: .atomic)
    }
    return checks
  }
}

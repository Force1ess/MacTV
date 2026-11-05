import AVFoundation
import Darwin
import Foundation

struct PlaybackFrameObservation: Codable, Sendable {
  let width: Int
  let height: Int
  let presentationTime: Double?
  let fresh: Bool
}

@MainActor enum PlaybackSustainProbe {
  private struct Sample: Codable {
    let wall: Double
    let position: Double
    let controlStatus: Int
    let waitingReason: String?
    let frame: PlaybackFrameObservation?
    let residentBytes: UInt64?
    let upstream: [String: Int]
  }
  private struct Report: Codable {
    let pid: Int32
    let phase: String
    let complete: Bool
    let samples: [Sample]
  }
  private static func residentSize() -> UInt64? {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
      pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    return result == KERN_SUCCESS ? info.resident_size : nil
  }
  static func run(model: AppModel, seconds: Int, phase: String, output: URL) async -> (checks: [String: Bool], diagnostics: [String: Any]) {
    guard CommandLine.arguments.contains("--ui-smoke"), (10...300).contains(seconds),
      let player = model.player, let item = player.currentItem else { return ([phase + "StartedWithPlayer": false], [:]) }
    let began = ProcessInfo.processInfo.systemUptime
    let initialPosition = player.currentTime().seconds
    var samples: [Sample] = []
    var nextSample = 0.0
    var lastProgress = began
    var lastPosition = initialPosition
    var largestNoProgress = 0.0
    var errored = false
    func save(complete: Bool) {
      let report = Report(pid: getpid(), phase: phase, complete: complete, samples: samples)
      if let data = try? JSONEncoder().encode(report) { try? data.write(to: output.appendingPathComponent(phase + "-progress.json"), options: .atomic) }
    }
    while ProcessInfo.processInfo.systemUptime - began < Double(seconds) {
      guard model.player === player, player.currentItem === item, item.status != .failed, model.notice == nil else { errored = true; break }
      let now = ProcessInfo.processInfo.systemUptime
      let position = player.currentTime().seconds
      if position.isFinite && position - lastPosition > 0.15 { lastProgress = now; lastPosition = position }
      largestNoProgress = max(largestNoProgress, now - lastProgress)
      if now - began >= nextSample {
        samples.append(Sample(wall: now - began, position: position.isFinite ? position : -1,
          controlStatus: player.timeControlStatus.rawValue, waitingReason: player.reasonForWaitingToPlay?.rawValue,
          frame: model.smokeDecodedFrameObservation(), residentBytes: residentSize(), upstream: await model.smokeRemoteStatistics()))
        nextSample += 3; save(complete: false)
      }
      do { try await Task.sleep(for: .seconds(1)) } catch { errored = true; break }
    }
    let wall = ProcessInfo.processInfo.systemUptime - began
    let advanced = player.currentTime().seconds - initialPosition
    save(complete: true)
    let decoded = samples.filter { $0.frame != nil }.count
    let fresh = samples.filter { $0.frame?.fresh == true }.count
    let rss = samples.compactMap(\.residentBytes)
    let diagnostics: [String: Any] = ["wallSeconds": wall, "advancedSeconds": advanced.isFinite ? advanced : -1,
      "largestNoProgressSeconds": largestNoProgress, "samples": samples.count, "decodedSamples": decoded,
      "freshSamples": fresh, "waitingSamples": samples.filter { $0.controlStatus == AVPlayer.TimeControlStatus.waitingToPlayAtSpecifiedRate.rawValue }.count,
      "residentStartBytes": rss.first ?? 0, "residentEndBytes": rss.last ?? 0, "residentPeakBytes": rss.max() ?? 0,
      "physicalDisplayVerified": false, "memoryLeakAbsenceProven": false]
    return ([phase + "CompletedBoundedDuration": !errored && wall >= Double(seconds) - 1,
      phase + "TimelineContinued": advanced.isFinite && advanced >= Double(seconds) * 0.9,
      phase + "NoLongStallObserved": largestNoProgress < 8,
      phase + "ContinuingDecodedFrames": decoded >= max(2, samples.count * 8 / 10) && fresh >= 2,
      phase + "ResidentMemoryObserved": rss.count == samples.count && !rss.isEmpty], diagnostics)
  }
}

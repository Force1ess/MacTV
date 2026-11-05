import Foundation

public enum PlaybackBenchmarkAudioOutput: String, Sendable {
  case system, tv
  public enum ValidationError: Error { case invalidArgument }
  public static func validated(arguments: [String]) throws -> Self {
    let matches = arguments.indices.filter { arguments[$0] == "--benchmark-audio-output" }
    guard !matches.isEmpty else { return .system }
    guard matches.count == 1, let index = matches.first, index + 1 < arguments.count,
      let output = Self(rawValue: arguments[index + 1]) else { throw ValidationError.invalidArgument }
    return output
  }
}

public enum PlaybackBenchmarkSession: String, Sendable {
  case guest, stored
  public static func validated(pluginID: String, option: String?) throws -> Self {
    guard ["mtv.bilibili", "mtv.quark"].contains(pluginID),
      let mode = Self(rawValue: option ?? (pluginID == "mtv.quark" ? "stored" : "guest")),
      pluginID != "mtv.quark" || mode == .stored
    else { throw MTVError.message("测速账号模式无效；夸克仅支持已登录模式") }
    return mode
  }
}

public struct PlaybackBenchmarkRecord: Codable, Sendable {
  public static let quarkSevenSecondPolicy = "quark-p99-7s-v1"
  public let schema: Int
  public let id: UUID
  public let reference: String
  public let variant: String
  public let trial: Int
  public let processCondition: String
  public var milestonesMS: [String: Double]
  public var outcome: String
  public var metadata: [String: String] = [:]
  /// Versioned provider policy is explicit; legacy rows retain decoded-dimension
  /// budgets, never a provider quality label. Cropped 4K keeps its height bound.
  public var startupBudgetMS: Double {
    if metadata["plugin"] == "mtv.quark", metadata["startupBudgetPolicy"] == Self.quarkSevenSecondPolicy { return 7000 }
    let components = (metadata["actualVideoDimensions"] ?? "").split(separator: "x", omittingEmptySubsequences: false)
    let dimensions = components.compactMap { Int($0) }
    guard components.count == 2, dimensions.count == 2,
      dimensions.allSatisfy({ (1...16384).contains($0) }) else { return 3000 }
    return max(dimensions[0], dimensions[1]) >= 3840 && min(dimensions[0], dimensions[1]) >= 1600 ? 6000 : 3000
  }
  public init(reference: String, variant: String, trial: Int) {
    schema = 1; id = UUID(); self.reference = reference; self.variant = variant; self.trial = trial
    processCondition = trial == 0 ? "firstMeasuredInProcess" : "sameProcessRepeat"
    milestonesMS = ["click": 0]; outcome = "running"
  }
  public mutating func mark(_ name: String, elapsedSeconds: Double) {
    guard milestonesMS[name] == nil, elapsedSeconds.isFinite, elapsedSeconds >= 0 else { return }
    milestonesMS[name] = elapsedSeconds * 1000
  }
  /// A displayed frame alone does not prove that playback started or stayed alive.
  public mutating func finish(reachedDecodedFrame: Bool, playbackFailed: Bool) {
    if playbackFailed { outcome = reachedDecodedFrame ? "failedAfterFrame" : "failed" }
    else if !reachedDecodedFrame { outcome = "timeout" }
    else if milestonesMS["timelinePlaying"] == nil { outcome = "notPlaying" }
    else { outcome = "ready" }
  }
  public static func comparisonCompatible(_ baseline: [Self], _ candidate: [Self]) -> Bool {
    guard !baseline.isEmpty, !candidate.isEmpty,
      Set(baseline.map(\.reference)) == Set(candidate.map(\.reference)) else { return false }
    return ["plugin", "session", "quality", "actualVideoDimensions", "observer", "playingObserver", "nativeLogStages", "completionPolicy", "nativeMediaSessionHost", "audioOutputRequested", "presentationRequested", "sourceTransport"].allSatisfy { key in
      Set(baseline.map { $0.metadata[key] }) == Set(candidate.map { $0.metadata[key] })
    }
  }
  public static func summary(_ records: [Self]) -> [String: Double] {
    let values = records.filter { $0.outcome == "ready" }.compactMap { $0.milestonesMS["renderReady"] }.sorted()
    var result = ["trials": Double(records.count), "successfulTrials": Double(values.count), "failedOrIncompleteTrials": Double(records.count - values.count),
      "successRate": records.isEmpty ? 0 : Double(values.count) / Double(records.count)]
    if !values.isEmpty {
      result["p50MS"] = values[Int(ceil(Double(values.count) * 0.5)) - 1]
      result["p95MS"] = values[Int(ceil(Double(values.count) * 0.95)) - 1]
      result["observedP99MS"] = values[Int(ceil(Double(values.count) * 0.99)) - 1]
      result["minMS"] = values.first; result["maxMS"] = values.last
    }
    for stage in ["resolveComplete", "prepareComplete", "displayReady", "timelinePlaying"] {
      let samples = records.filter { $0.outcome == "ready" }.compactMap { $0.milestonesMS[stage] }.sorted()
      if !samples.isEmpty {
        result[stage + "P50MS"] = samples[Int(ceil(Double(samples.count) * 0.5)) - 1]
        result[stage + "P95MS"] = samples[Int(ceil(Double(samples.count) * 0.95)) - 1]
      }
    }
    result["rebufferObservedTrials"] = Double(records.filter { $0.milestonesMS["firstRebuffer"] != nil }.count)
    result["failedAfterFrameTrials"] = Double(records.filter { $0.outcome == "failedAfterFrame" }.count)
    result["frameWithoutPlayingTrials"] = Double(records.filter { $0.outcome == "notPlaying" }.count)
    let misses = records.filter { $0.outcome != "ready" || ($0.milestonesMS["renderReady"] ?? .infinity) > $0.startupBudgetMS }.count
    let budgets = Set(records.map(\.startupBudgetMS))
    if budgets.count <= 1 { result["startupBudgetMS"] = budgets.first ?? 3000 }
    else { result["minimumStartupBudgetMS"] = budgets.min(); result["maximumStartupBudgetMS"] = budgets.max() }
    result["deadlineMissesIncludingFailures"] = Double(misses)
    result["deadlineMissRate"] = records.isEmpty ? 1 : Double(misses) / Double(records.count)
    result["minimum100AttemptsForP99Met"] = records.count >= 100 ? 1 : 0
    return result
  }
}

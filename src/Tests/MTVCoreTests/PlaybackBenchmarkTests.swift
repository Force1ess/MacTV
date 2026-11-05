import Foundation
import Testing
@testable import MTVCore
struct PlaybackBenchmarkTests {
  @Test func approvedQuarkBudgetDoesNotRewriteLegacyOrOtherProviders() {
    for dimensions in ["1920x1038", "3840x2160", "unknown"] {
      var old = PlaybackBenchmarkRecord(reference:"test",variant:"baseline",trial:0)
      old.metadata = ["plugin":"mtv.quark","actualVideoDimensions":dimensions]
      old.outcome = "ready"; old.mark("renderReady",elapsedSeconds:6.9)
      let oldBudget = old.startupBudgetMS
      var reviewed = old
      reviewed.metadata["startupBudgetPolicy"] = PlaybackBenchmarkRecord.quarkSevenSecondPolicy
      #expect(reviewed.startupBudgetMS == 7000 && old.startupBudgetMS == oldBudget)
      #expect(reviewed.milestonesMS == old.milestonesMS)
      #expect(PlaybackBenchmarkRecord.summary([reviewed])["deadlineMissesIncludingFailures"] == 0)
      reviewed.metadata["plugin"] = "mtv.bilibili"
      #expect(reviewed.startupBudgetMS == oldBudget)
    }
  }
  @Test func displayNotificationDoesNotReplaceVerifiedFrameTiming() {
    var record = PlaybackBenchmarkRecord(reference: "test", variant: "baseline", trial: 0)
    record.mark("displayReady", elapsedSeconds: 0.1)
    record.mark("timelinePlaying", elapsedSeconds: 0.2)
    record.finish(reachedDecodedFrame: false, playbackFailed: false)
    #expect(PlaybackBenchmarkRecord.summary([record])["successfulTrials"] == 0)
    record.mark("renderReady", elapsedSeconds: 0.8)
    record.finish(reachedDecodedFrame: true, playbackFailed: false)
    let result = PlaybackBenchmarkRecord.summary([record])
    #expect(result["observedP99MS"] == 800 && result["displayReadyP50MS"] == 100)
  }
  @Test func audioRouteIsExplicitAndInvalidArgumentsDoNotSelectAnotherRoute() throws {
    #expect(try PlaybackBenchmarkAudioOutput.validated(arguments: []) == .system)
    #expect(try PlaybackBenchmarkAudioOutput.validated(arguments: ["--benchmark-audio-output", "tv"]) == .tv)
    for arguments in [["--benchmark-audio-output"], ["--benchmark-audio-output", "fallback"], ["--benchmark-audio-output", "--benchmark-runs"], ["--benchmark-audio-output", "tv", "--benchmark-audio-output", "system"]] {
      #expect(throws: PlaybackBenchmarkAudioOutput.ValidationError.self) { try PlaybackBenchmarkAudioOutput.validated(arguments: arguments) }
    }
    var baseline = PlaybackBenchmarkRecord(reference: "test", variant: "baseline", trial: 0)
    var candidate = baseline
    baseline.metadata["audioOutputRequested"] = "system"
    candidate.metadata["audioOutputRequested"] = "tv"
    #expect(!PlaybackBenchmarkRecord.comparisonCompatible([baseline], [candidate]))
    candidate.metadata = baseline.metadata
    baseline.metadata["presentationRequested"] = "windowed"
    candidate.metadata["presentationRequested"] = "full-screen"
    #expect(!PlaybackBenchmarkRecord.comparisonCompatible([baseline], [candidate]))
  }
  @Test func fourKBudgetDoesNotRelaxLowerQualityOrUnknownSamples() {
    var record = PlaybackBenchmarkRecord(reference: "test", variant: "baseline", trial: 0)
    record.outcome = "ready"; record.mark("renderReady", elapsedSeconds: 5.5)
    for dimensions in ["1920x1080", "unknown", "3840x2160xjunk", "3840x", "3840x0"] {
      record.metadata["actualVideoDimensions"] = dimensions
      #expect(record.startupBudgetMS == 3000)
      #expect(PlaybackBenchmarkRecord.summary([record])["deadlineMissesIncludingFailures"] == 1)
    }
    for dimensions in ["3840x2160", "3840x1600", "4096x1716"] {
      record.metadata["actualVideoDimensions"] = dimensions
      #expect(record.startupBudgetMS == 6000)
      #expect(PlaybackBenchmarkRecord.summary([record])["deadlineMissesIncludingFailures"] == 0)
    }
    var lowerQuality = record
    lowerQuality.metadata["actualVideoDimensions"] = "1920x1080"
    #expect(!PlaybackBenchmarkRecord.comparisonCompatible([record], [lowerQuality]))
    let mixed = PlaybackBenchmarkRecord.summary([record, lowerQuality])
    #expect(mixed["startupBudgetMS"] == nil)
    #expect(mixed["deadlineMissesIncludingFailures"] == 1)
  }
  @Test func rejectsComparisonWhenObservationPolicyOrQualityChanges() {
    let baseline = PlaybackBenchmarkRecord(reference: "test", variant: "baseline", trial: 0)
    var candidate = PlaybackBenchmarkRecord(reference: "test", variant: "candidate", trial: 0)
    #expect(PlaybackBenchmarkRecord.comparisonCompatible([baseline], [candidate]))
    candidate.metadata["completionPolicy"] = "decodedFrameAndPlayingNoObservedFailure"
    #expect(!PlaybackBenchmarkRecord.comparisonCompatible([baseline], [candidate]))
    candidate.metadata = ["nativeLogStages":"on"]
    #expect(!PlaybackBenchmarkRecord.comparisonCompatible([baseline], [candidate]))
    candidate.metadata = ["quality": "64"]
    #expect(!PlaybackBenchmarkRecord.comparisonCompatible([baseline], [candidate]))
    #expect(!PlaybackBenchmarkRecord.comparisonCompatible([], [candidate]))
  }
  @Test func frameWithoutPlaybackOrLaterFailureIsNotASuccess() {
    var record = PlaybackBenchmarkRecord(reference: "test", variant: "baseline", trial: 0)
    record.mark("renderReady", elapsedSeconds: 0.5)
    record.finish(reachedDecodedFrame: true, playbackFailed: false)
    #expect(record.outcome == "notPlaying")
    record.mark("timelinePlaying", elapsedSeconds: 0.6)
    record.finish(reachedDecodedFrame: true, playbackFailed: true)
    #expect(record.outcome == "failedAfterFrame")
    let summary = PlaybackBenchmarkRecord.summary([record])
    #expect(summary["successfulTrials"] == 0 && summary["failedAfterFrameTrials"] == 1)
    #expect(summary["deadlineMissesIncludingFailures"] == 1)
    record.finish(reachedDecodedFrame: true, playbackFailed: false)
    #expect(record.outcome == "ready")
    record.finish(reachedDecodedFrame: false, playbackFailed: false)
    #expect(record.outcome == "timeout")
    record.finish(reachedDecodedFrame: false, playbackFailed: true)
    #expect(record.outcome == "failed")
  }
  @Test func rejectsInvalidTimesAndKeepsFirstObservation() {
    var r = PlaybackBenchmarkRecord(reference: "test", variant: "baseline", trial: 0)
    r.mark("renderReady", elapsedSeconds: .nan); r.mark("renderReady", elapsedSeconds: -1)
    #expect(r.milestonesMS["renderReady"] == nil)
    r.mark("renderReady", elapsedSeconds: 1.2); r.mark("renderReady", elapsedSeconds: 9)
    #expect(r.milestonesMS["renderReady"] == 1200)
  }
  @Test func retainsFailuresAndUsesDeclaredNearestRank() throws {
    var records = (0..<5).map { PlaybackBenchmarkRecord(reference: "test", variant: "baseline", trial: $0) }
    for i in 0..<4 { records[i].outcome = "ready"; records[i].mark("renderReady", elapsedSeconds: Double(i + 1)) }
    records[4].outcome = "timeout"
    let s = PlaybackBenchmarkRecord.summary(records)
    #expect(s["trials"] == 5 && s["successfulTrials"] == 4 && s["failedOrIncompleteTrials"] == 1)
    #expect(s["p50MS"] == 2000 && s["p95MS"] == 4000)
    #expect(s["deadlineMissesIncludingFailures"] == 2 && s["minimum100AttemptsForP99Met"] == 0)
    let decoded = try JSONDecoder().decode(PlaybackBenchmarkRecord.self, from: JSONEncoder().encode(records[0]))
    #expect(decoded.milestonesMS == records[0].milestonesMS)
  }
}

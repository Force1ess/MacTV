import AVFoundation
import Foundation
import MTVCore

extension AppModel {
  func startPlaybackBenchmark(reference: String, variant: String, trial: Int) {
    playbackBenchmark = PlaybackBenchmarkRecord(reference: reference, variant: variant, trial: trial)
    playbackBenchmarkStarted = ProcessInfo.processInfo.systemUptime
  }
  func markPlaybackBenchmark(_ name: String) {
    guard playbackBenchmark != nil else { return }
    playbackBenchmark?.mark(name, elapsedSeconds: ProcessInfo.processInfo.systemUptime - playbackBenchmarkStarted)
  }
  func benchmarkDisplayReady(_ value: AVPlayer) {
    guard player === value else { return }; markPlaybackBenchmark("displayReady")
  }
}

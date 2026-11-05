import Foundation

/// Observes only requested, ready playback. It does not infer a network cause.
public struct PlaybackProgressMonitor: Sendable {
  private var lastPosition: Double?
  private var lastProgress: Double?
  public init() {}
  public mutating func reset() { lastPosition = nil; lastProgress = nil }
  public mutating func stalled(now: Double, position: Double, wantsPlayback: Bool, ready: Bool, ended: Bool) -> Bool {
    guard now.isFinite, position.isFinite, wantsPlayback, ready, !ended else { reset(); return false }
    guard let previous = lastPosition, let progressedAt = lastProgress, now >= progressedAt else {
      lastPosition = position; lastProgress = now; return false
    }
    if abs(position - previous) > 0.1 { lastPosition = position; lastProgress = now; return false }
    return now - progressedAt >= 12
  }
}

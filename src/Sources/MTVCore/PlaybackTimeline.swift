import Foundation

public enum PlaybackTimeline {
  public static func target(_ requested: Double, duration: Double) -> Double? {
    guard requested.isFinite, duration.isFinite, duration > 0 else { return nil }
    return min(max(0, requested), max(0, duration - 0.25))
  }
  public static func timecode(_ time: Double) -> String {
    guard time.isFinite, time >= 0, time < 86_400 * 365 else { return "--:--" }
    let seconds = Int(time)
    return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
      : String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }
}

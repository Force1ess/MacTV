import Foundation

/// Preserve presentation offsets; reject incomplete or unrelated timelines rather than trimming a film.
public struct SplitPlaybackTiming: Equatable, Sendable {
  public let videoOffset: Double
  public let audioOffset: Double
  public init(videoStart: Double, videoDuration: Double, audioStart: Double, audioDuration: Double) throws {
    guard [videoStart, videoDuration, audioStart, audioDuration].allSatisfy(\.isFinite),
      videoDuration > 0, audioDuration > 0,
      (videoStart + videoDuration).isFinite, (audioStart + audioDuration).isFinite,
      abs(videoStart - audioStart) <= 0.5,
      abs((videoStart + videoDuration) - (audioStart + audioDuration)) <= 0.5 else {
      throw MTVError.message("分轨音视频的时间范围不匹配，未截短或替换片源")
    }
    let origin = min(videoStart, audioStart)
    videoOffset = videoStart - origin; audioOffset = audioStart - origin
  }
}

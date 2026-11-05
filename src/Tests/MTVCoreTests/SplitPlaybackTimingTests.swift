import Testing
@testable import MTVCore

struct SplitPlaybackTimingTests {
  @Test func preservesRelativeStartAndCodecPaddingWithoutTrimming() throws {
    let result = try SplitPlaybackTiming(videoStart: 1, videoDuration: 60, audioStart: 0.98, audioDuration: 60.04)
    #expect(abs(result.videoOffset - 0.02) < 0.000001)
    #expect(result.audioOffset == 0)
  }
  @Test func rejectsMissingUnboundedOrUnrelatedTracks() {
    for (start, duration) in [(0.0, 0.0), (0, Double.infinity), (Double.nan, 60), (0, 20), (2, 60)] {
      #expect(throws: (any Error).self) { try SplitPlaybackTiming(videoStart: 0, videoDuration: 60, audioStart: start, audioDuration: duration) }
    }
  }
}

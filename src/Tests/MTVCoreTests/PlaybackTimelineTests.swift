import Testing
@testable import MTVCore

struct PlaybackTimelineTests {
  @Test func validatesAndClampsSeekWithoutAccidentalEOF() {
    #expect(PlaybackTimeline.target(-10, duration: 45) == 0)
    #expect(PlaybackTimeline.target(100, duration: 45) == 44.75)
    #expect(PlaybackTimeline.target(12.5, duration: 45) == 12.5)
    #expect(PlaybackTimeline.target(1, duration: 0.1) == 0)
    #expect(PlaybackTimeline.target(.nan, duration: 45) == nil)
    #expect(PlaybackTimeline.target(1, duration: .infinity) == nil)
    #expect(PlaybackTimeline.target(1, duration: 0) == nil)
  }
  @Test func formatsFeatureLengthFilmsAndUnknownDuration() {
    #expect(PlaybackTimeline.timecode(3760.8) == "1:02:40")
    #expect(PlaybackTimeline.timecode(45) == "00:45")
    #expect(PlaybackTimeline.timecode(.nan) == "--:--")
  }
}

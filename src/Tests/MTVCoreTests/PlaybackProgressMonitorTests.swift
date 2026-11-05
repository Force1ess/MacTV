import Testing
@testable import MTVCore

struct PlaybackProgressMonitorTests {
  @Test func distinguishesStallFromPausePreparationEndAndRecovery() {
    var monitor = PlaybackProgressMonitor()
    func sample(_ time: Double, _ position: Double, playing: Bool = true, ready: Bool = true, ended: Bool = false) -> Bool {
      monitor.stalled(now: time, position: position, wantsPlayback: playing, ready: ready, ended: ended)
    }
    #expect(!sample(0, 20)); #expect(!sample(11, 20)); #expect(sample(12, 20))
    #expect(!sample(13, 20.2)); #expect(!sample(24, 20.2)); #expect(sample(25, 20.2))
    #expect(!sample(40, 20.2, playing: false)); #expect(!sample(60, 20.2))
    #expect(!sample(90, 20.2, ready: false)); #expect(!sample(100, 20.2))
    #expect(!sample(130, 20.2, ended: true)); #expect(!sample(140, 20.2))
    #expect(!sample(141, 1800)); #expect(!sample(152, 1800))
    #expect(sample(153, 1800)); monitor.reset(); #expect(!sample(180, 1800))
    #expect(!sample(100, 1800)); #expect(!sample(200, .nan))
  }
}

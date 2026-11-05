import Testing
@testable import MTVCore

struct PlaybackBenchmarkSessionTests {
  @Test func explicitSessionPreservesGuestBaselineAndRejectsCloudGuest() throws {
    #expect(try PlaybackBenchmarkSession.validated(pluginID: "mtv.bilibili", option: nil) == .guest)
    #expect(try PlaybackBenchmarkSession.validated(pluginID: "mtv.bilibili", option: "stored") == .stored)
    #expect(try PlaybackBenchmarkSession.validated(pluginID: "mtv.quark", option: nil) == .stored)
    #expect(throws: (any Error).self) { try PlaybackBenchmarkSession.validated(pluginID: "mtv.quark", option: "guest") }
    #expect(throws: (any Error).self) { try PlaybackBenchmarkSession.validated(pluginID: "mtv.bilibili", option: "fallback") }
    #expect(throws: (any Error).self) { try PlaybackBenchmarkSession.validated(pluginID: "unknown", option: "guest") }
  }
}

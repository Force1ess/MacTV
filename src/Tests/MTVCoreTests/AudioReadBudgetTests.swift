import Foundation
import Testing
@testable import MTVCore

struct AudioReadBudgetTests {
  private func budget() throws -> AudioReadBudget {
    AudioReadBudget(wave: try FloatAudioWave(sampleRate: 48000, channels: 2, frames: 48000 * 60), startFrame: 48000 * 12)
  }
  private func registered(_ value: AudioReadBudget) async throws {
    for _ in 0..<1000 {
      if await value.pendingCount == 1 { return }
      await Task.yield()
    }
    throw NSError(domain: "AudioBudgetWaitDidNotRegister", code: 1)
  }
  @Test func initializedNonzeroStartIgnoresTransientZeroAndClockReleasesRead() async throws {
    let value = try budget(), consumer = UUID()
    await value.update(frame: 0)
    try await value.allow(throughFrame: 48000 * 15, consumer: consumer)
    let task = Task { try await value.allow(throughFrame: 48000 * 16, consumer: consumer) }
    try await registered(value)
    await value.update(frame: 48000 * 13)
    try await task.value
    #expect(await value.pendingCount == 0)
    await value.cancel()
  }
  @Test func backwardsSeekReleasesExactlyOneOldBoundedRead() async throws {
    let value = try budget(), consumer = UUID()
    let oldRead = Task { try await value.allow(throughFrame: 48000 * 25, consumer: consumer) }
    try await registered(value)
    await value.seek(frame: 48000 * 6)
    try await oldRead.value
    let nextRead = Task { try await value.allow(throughFrame: 48000 * 26, consumer: consumer) }
    try await registered(value)
    await value.cancel()
    do { try await nextRead.value; Issue.record("Canceled read unexpectedly completed") }
    catch { #expect(error is CancellationError) }
  }
  @Test func requestCancellationDoesNotCancelAnotherConsumerOrWholePlayback() async throws {
    let value = try budget(), first = UUID(), second = UUID()
    let task = Task { try await value.allow(throughFrame: 48000 * 20, consumer: first) }
    try await registered(value); task.cancel()
    do { try await task.value; Issue.record("Request cancellation was ignored") }
    catch { #expect(error is CancellationError) }
    try await value.allow(throughFrame: 48000 * 14, consumer: second)
    await value.cancel()
    do { try await value.allow(throughFrame: 1, consumer: second); Issue.record("Closed playback accepted a read") }
    catch { #expect(error is CancellationError) }
  }
  @Test func seekingAllowsOneInFlightConsumersNextReadAndCapsConsumers() async throws {
    let value = try budget(), consumer = UUID()
    try await value.allow(throughFrame: 48000 * 14, consumer: consumer)
    await value.seek(frame: 48000 * 1)
    try await value.allow(throughFrame: 48000 * 20, consumer: consumer)
    let blocked = Task { try await value.allow(throughFrame: 48000 * 21, consumer: consumer) }
    try await registered(value)
    await value.release(consumer)
    do { try await blocked.value; Issue.record("Released consumer still completed") }
    catch { #expect(error is CancellationError) }
    for _ in 0..<8 { try await value.allow(throughFrame: 1, consumer: UUID()) }
    do { try await value.allow(throughFrame: 1, consumer: UUID()); Issue.record("Accepted ninth concurrent consumer") }
    catch { #expect(!(error is CancellationError)) }
    await value.cancel()
  }
}

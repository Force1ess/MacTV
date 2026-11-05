import Foundation

/// Per-playback flow control. Call seek before requesting the decoder seek, and
/// cancel before destroying the player. A consumer is one HTTP response.
public actor AudioReadBudget {
  private let rate: Int64
  private let total: Int64
  private var clock: Int64
  private var initializedClock: Bool
  private var closed = false
  private var consumers = Set<UUID>()
  private var seekAllowance = Set<UUID>()
  private struct Waiting {
    let end: Int64
    let continuation: CheckedContinuation<Void, Error>
  }
  private var waiting: [UUID: Waiting] = [:]
  public var pendingCount: Int { waiting.count }
  public init(wave: FloatAudioWave, startFrame: Int64) {
    rate = Int64(wave.sampleRate); total = wave.frames
    clock = min(wave.frames, max(0, startFrame)); initializedClock = clock == 0
  }
  public func allow(throughFrame end: Int64, consumer: UUID) async throws {
    try Task.checkCancellation()
    guard !closed else { throw CancellationError() }
    guard end > 0, end <= total, consumers.contains(consumer) || consumers.count < 8,
      waiting[consumer] == nil else { throw MTVError.message("系统音轨读取并发或范围无效") }
    consumers.insert(consumer)
    if end <= clock + 3 * rate { return }
    if seekAllowance.remove(consumer) != nil { return }
    try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        waiting[consumer] = Waiting(end: end, continuation: continuation)
      }
    }, onCancel: { Task { await self.release(consumer) } })
    try Task.checkCancellation()
  }
  public func update(frame: Int64) {
    guard !closed, frame >= 0, frame <= total else { return }
    // VLC can report zero while a nonzero start is still being prepared.
    guard frame != 0 || initializedClock else { return }
    initializedClock = true; clock = frame
    let ready = waiting.filter { $0.value.end <= clock + 3 * rate }.map(\.key)
    for id in ready { waiting.removeValue(forKey: id)?.continuation.resume() }
  }
  public func seek(frame: Int64) {
    guard !closed, frame >= 0, frame <= total else { return }
    initializedClock = true; clock = frame
    seekAllowance = consumers
    // Unblock one already pending bounded read per consumer. Without this, a
    // backwards seek can wait forever on the old synchronous slave input.
    let pending = waiting; waiting.removeAll()
    for (id, value) in pending {
      seekAllowance.remove(id); value.continuation.resume()
    }
  }
  public func release(_ consumer: UUID) {
    consumers.remove(consumer); seekAllowance.remove(consumer)
    waiting.removeValue(forKey: consumer)?.continuation.resume(throwing: CancellationError())
  }
  public func cancel() {
    guard !closed else { return }; closed = true
    let pending = waiting; waiting.removeAll(); consumers.removeAll(); seekAllowance.removeAll()
    for value in pending.values { value.continuation.resume(throwing: CancellationError()) }
  }
}

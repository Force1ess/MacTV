import Foundation

/// Observes an owned child without blocking Swift's cooperative executor.
/// Attach before starting it. Cancellation/termination stays with its owner;
/// wait() completes only when Foundation reports the actual process exit.
public final class ProcessExitObservation: @unchecked Sendable {
  public struct Result: Sendable, Equatable {
    public let status: Int32
    public let signalled: Bool
  }
  private let lock = NSLock()
  private var result: Result?
  private var waiters: [CheckedContinuation<Result, Never>] = []
  public init(_ process: Process) throws {
    guard !process.isRunning, process.processIdentifier <= 0 else { throw MTVError.message("Attach exit observation before starting the child process") }
    let previous = process.terminationHandler
    process.terminationHandler = { [self] child in
      finish(Result(status: child.terminationStatus, signalled: child.terminationReason == .uncaughtSignal))
      previous?(child)
    }
  }
  public func wait() async -> Result {
    await withCheckedContinuation { continuation in
      lock.lock()
      if let result { lock.unlock(); continuation.resume(returning: result) }
      else { waiters.append(continuation); lock.unlock() }
    }
  }
  private func finish(_ result: Result) {
    lock.lock()
    guard self.result == nil else { lock.unlock(); return }
    self.result = result; let values = waiters; waiters = []; lock.unlock()
    for waiter in values { waiter.resume(returning: result) }
  }
}

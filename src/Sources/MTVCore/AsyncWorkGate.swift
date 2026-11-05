import Foundation

public actor AsyncWorkGate {
  private let limit: Int
  private var active = 0
  private var order: [UUID] = []
  private var waiting: [UUID:CheckedContinuation<Void,Error>] = [:]
  public init(limit: Int) { self.limit = max(1,limit) }
  private func acquire() async throws {
    let id = UUID()
    try await withTaskCancellationHandler(operation: {
      try Task.checkCancellation()
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void,Error>) in
        if active < limit { active += 1; continuation.resume() }
        else { order.append(id); waiting[id] = continuation }
      }
    },onCancel:{ Task { await self.cancel(id) } })
  }
  private func cancel(_ id: UUID) {
    if let value = waiting.removeValue(forKey:id) { order.removeAll{$0==id}; value.resume(throwing:CancellationError()) }
  }
  private func release() {
    while !order.isEmpty {
      let id = order.removeFirst()
      if let value = waiting.removeValue(forKey:id) { value.resume(); return }
    }
    active -= 1
  }
  public func run<T:Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await acquire()
    do { try Task.checkCancellation(); let result = try await operation(); release(); return result }
    catch { release(); throw error }
  }
}

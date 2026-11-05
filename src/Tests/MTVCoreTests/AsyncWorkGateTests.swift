import Foundation
import Testing
@testable import MTVCore

struct AsyncWorkGateTests {
  actor Counter {
    var active = 0, maximum = 0, completed = 0
    func operation() async throws -> Int {
      active += 1; maximum = max(maximum,active)
      defer { active -= 1 }
      try await Task.sleep(for:.milliseconds(5)); completed += 1; return completed
    }
    func snapshot() -> (Int,Int) { (maximum,completed) }
  }
  @Test func workStaysBoundedAndCancelledWaitersDoNotLeakSlots() async throws {
    let gate = AsyncWorkGate(limit:2), counter = Counter()
    try await withThrowingTaskGroup(of:Int.self) { group in
      for _ in 0..<12 { group.addTask { try await gate.run { try await counter.operation() } } }
      for try await _ in group {}
    }
    let (maximum,count) = await counter.snapshot(); #expect(maximum <= 2 && count == 12)
    let cancelled = Task { try await gate.run { try await Task.sleep(for:.seconds(10)); return 1 } }
    cancelled.cancel()
    await #expect(throws: CancellationError.self) { try await cancelled.value }
    #expect(try await gate.run { 7 } == 7)
  }
}

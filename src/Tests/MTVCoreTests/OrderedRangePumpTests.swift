import Foundation
import Testing
@testable import MTVCore

struct OrderedRangePumpTests {
  actor StreamRecorder {
    var output = Data()
    func append(_ bytes: Data) { output.append(bytes) }
    func snapshot() -> Data { output }
  }
  final class Cancellations: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func record() { lock.lock(); value += 1; lock.unlock() }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; return value }
  }
  @Test func streamingFailureCancelsEveryPrefetchedRead() async {
    let cancellations = Cancellations()
    await #expect(throws: Error.self) {
      try await OrderedRangePump.stream(start: 0, length: 20, chunkSize: 5, depth: 4,
        open: { offset, _ in
          .init(chunks: AsyncThrowingStream { output in
            if offset == 0 { output.finish(throwing: URLError(.networkConnectionLost)) }
          }, cancel: { cancellations.record() })
        }, send: { _ in Issue.record("Failed bytes must not reach the consumer") })
    }
    #expect(cancellations.count() == 4)
  }
  @Test func streamingDeliversBeforeTheRangeCompletes() async throws {
    let stream = AsyncThrowingStream<Data, Error>.makeStream()
    let recorder = StreamRecorder()
    stream.continuation.yield(Data([1]))
    try await OrderedRangePump.stream(start: 0, length: 2,
      open: { _, _ in .init(chunks: stream.stream, cancel: {}) },
      send: { data in
        await recorder.append(data)
        // The producer cannot finish until its first bytes have actually been
        // delivered. A whole-range buffering implementation would deadlock.
        if data == Data([1]) {
          stream.continuation.yield(Data([2])); stream.continuation.finish()
        }
      })
    #expect(await recorder.snapshot() == Data([1, 2]))
  }
  @Test func startupReadDoesNotCompeteWithFutureRanges() async throws {
    let first = AsyncThrowingStream<Data, Error>.makeStream()
    let opened = Cancellations(), recorder = StreamRecorder()
    first.continuation.yield(Data([0]))
    try await OrderedRangePump.stream(start:0,length:3,chunkSize:1,depth:3,initialDepth:1,
      open: { offset, _ in
        opened.record()
        let chunks = offset == 0 ? first.stream : AsyncThrowingStream<Data,Error> { $0.yield(Data([UInt8(offset)])); $0.finish() }
        return .init(chunks:chunks,cancel:{})
      }, send: { data in
        await recorder.append(data)
        if data == Data([0]) {
          #expect(opened.count()==1)
          first.continuation.finish()
        }
      })
    #expect(opened.count()==3)
    #expect(await recorder.snapshot()==Data([0,1,2]))
  }
  @Test func streamingMaintainsOrderAndRejectsIncompleteRanges() async throws {
    let recorder = StreamRecorder()
    try await OrderedRangePump.stream(start: 0, length: 20, chunkSize: 5, depth: 4,
      open: { offset, count in
        .init(chunks: AsyncThrowingStream { output in
          for value in offset..<(offset + count) { output.yield(Data([UInt8(value)])) }
          output.finish()
        }, cancel: {})
      }, send: { await recorder.append($0) })
    #expect(await recorder.snapshot() == Data(0..<20))
    await #expect(throws: Error.self) {
      try await OrderedRangePump.stream(start: 0, length: 2,
        open: { _, _ in .init(chunks: AsyncThrowingStream { $0.yield(Data([1])); $0.finish() }, cancel: {}) },
        send: { _ in })
    }
  }
  actor Recorder {
    var output = Data(), active = 0, maximum = 0, readCount = 0
    func read(_ offset: Int, _ count: Int) async throws -> Data {
      active += 1; maximum = max(maximum, active); readCount += 1
      defer { active -= 1 }
      try await Task.sleep(for: .milliseconds(offset == 0 ? 30 : 1))
      return Data((offset..<(offset + count)).map { UInt8($0 % 256) })
    }
    func append(_ bytes: Data) { output.append(bytes) }
    func snapshot() -> (Data, Int, Int) { (output, maximum, readCount) }
  }
  @Test(arguments: [1, 2, 4]) func outOfOrderDownloadsArriveInOrderWithinBudget(depth: Int) async throws {
    let recorder = Recorder()
    try await OrderedRangePump.transfer(start: 0, length: 1000, chunkSize: 100, depth: depth,
      read: { try await recorder.read($0, $1) }, send: { await recorder.append($0) })
    let (data, maximum, count) = await recorder.snapshot()
    #expect(data == Data((0..<1000).map { UInt8($0 % 256) }))
    #expect(maximum == depth && count == 10)
  }
  @Test func shortReadsAndInvalidBoundsFail() async {
    await #expect(throws: Error.self) {
      try await OrderedRangePump.transfer(start: 0, length: 2, read: { _, _ in Data() }, send: { _ in })
    }
    await #expect(throws: Error.self) {
      try await OrderedRangePump.transfer(start: Int.max, length: 2, read: { _, _ in Data() }, send: { _ in })
    }
  }
  @Test func cancellationStopsOutstandingDownloads() async throws {
    let recorder = Recorder()
    let task = Task {
      try await OrderedRangePump.transfer(start: 0, length: 1000, chunkSize: 100,
        read: { try await recorder.read($0, $1) }, send: { await recorder.append($0) })
    }
    try await Task.sleep(for: .milliseconds(5)); task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let (data, _, count) = await recorder.snapshot()
    #expect(data.isEmpty && count <= 2)
  }
}

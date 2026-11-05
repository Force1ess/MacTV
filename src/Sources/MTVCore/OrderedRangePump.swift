import Foundation

/// Bounded parallel reads with ordered, backpressured delivery. A seek that
/// disconnects its HTTP consumer cancels all outstanding reads with the parent.
public enum OrderedRangePump {
  public struct Read: Sendable {
    public let chunks: AsyncThrowingStream<Data, Error>
    public let cancel: @Sendable () -> Void
    public init(chunks: AsyncThrowingStream<Data, Error>, cancel: @escaping @Sendable () -> Void) {
      self.chunks = chunks; self.cancel = cancel
    }
  }

  /// Every opened read is capped at chunkSize bytes by its transport. Prefetch
  /// remains bounded by depth, while the head read delivers bytes immediately.
  public static func stream(start: Int, length: Int, chunkSize: Int = 1_048_576, depth: Int = 2, initialDepth: Int? = nil,
    open: @escaping @Sendable (Int, Int) throws -> Read,
    send: @escaping @Sendable (Data) async throws -> Void) async throws {
    let initialDepth = initialDepth ?? depth
    guard start >= 0, length > 0, start <= Int.max - length,
      (1...HTTPByteRange.maximumStreamingCount).contains(chunkSize), (1...4).contains(depth),
      (1...depth).contains(initialDepth) else {
      throw MTVError.message("Invalid bounded range transfer")
    }
    let end = start + length
    var requested = start, delivered = start
    var pending: [(count: Int, read: Read)] = []
    defer { pending.forEach { $0.read.cancel() } }
    func enqueue() throws {
      let count = min(chunkSize, end - requested)
      pending.append((count, try open(requested, count))); requested += count
    }
    for _ in 0..<initialDepth where requested < end { try Task.checkCancellation(); try enqueue() }
    while let head = pending.first {
      var received = 0
      for try await data in head.read.chunks {
        try Task.checkCancellation()
        guard !data.isEmpty, data.count <= head.count - received else {
          throw MTVError.message("Invalid streaming range length")
        }
        try await send(data); received += data.count; delivered += data.count
      }
      try Task.checkCancellation()
      guard received == head.count else { throw MTVError.message("Incomplete streaming range read") }
      pending.removeFirst()
      head.read.cancel()
      while pending.count < depth && requested < end { try enqueue() }
    }
    guard delivered == end else { throw MTVError.message("Range transfer ended early") }
  }

  public static func transfer(start: Int, length: Int, chunkSize: Int = 1_048_576, depth: Int = 2,
    read: @escaping @Sendable (Int, Int) async throws -> Data,
    send: @escaping @Sendable (Data) async throws -> Void) async throws {
    guard start >= 0, length > 0, start <= Int.max - length,
      (1...4_194_304).contains(chunkSize), (1...4).contains(depth) else {
      throw MTVError.message("Invalid bounded range transfer")
    }
    let end = start + length
    try await withThrowingTaskGroup(of: (Int, Data).self) { group in
      var requested = start, delivered = start, pending: [Int: Data] = [:]
      func enqueue(_ offset: Int) {
        let count = min(chunkSize, end - offset)
        group.addTask {
          try Task.checkCancellation()
          let data = try await read(offset, count)
          try Task.checkCancellation()
          guard data.count == count else { throw MTVError.message("Incomplete bounded range read") }
          return (offset, data)
        }
      }
      for _ in 0..<depth where requested < end {
        enqueue(requested); requested += min(chunkSize, end - requested)
      }
      while let (offset, data) = try await group.next() {
        try Task.checkCancellation()
        pending[offset] = data
        while let next = pending.removeValue(forKey: delivered) {
          try Task.checkCancellation()
          try await send(next)
          delivered += next.count
          if requested < end { enqueue(requested); requested += min(chunkSize, end - requested) }
        }
      }
      guard delivered == end else { throw MTVError.message("Range transfer ended early") }
    }
  }
}

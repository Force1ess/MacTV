import Foundation

public struct PluginRPCRequest: Sendable {
  public enum Kind: Sendable { case library, fetch }
  public let id: Int
  public let kind: Kind
  public let argument: String
  public let options: String
  public init(frame: [String:Any], expectedID: Int) throws {
    guard (1...64).contains(expectedID), frame["id"] as? Int==expectedID else { throw MTVError.message("Invalid async plugin request ID") }
    id=expectedID
    if frame["type"] as? String=="libraryAsync", Set(frame.keys)==["type","id","service","input"],
      let value=frame["service"] as? String, value.utf8.count<=128,
      let input=frame["input"] as? String, input.utf8.count<=16_384 {
      kind = .library; argument=value; options=input
    } else if frame["type"] as? String=="fetchAsync", Set(frame.keys)==["type","id","url","options"],
      let value=frame["url"] as? String, value.utf8.count<=16_384,
      let input=frame["options"] as? String, input.utf8.count<=131_072 {
      kind = .fetch; argument=value; options=input
    } else { throw MTVError.message("Invalid async plugin request") }
  }
}

/// One invocation owns its children. Replies can finish out of order, but each
/// complete frame is serialized and carries its original request identity.
public final class PluginAsyncRPC: @unchecked Sendable {
  private let reader: FileHandle, writer: FileHandle
  private let lock=NSLock()
  private var closed=false
  private var failure: Error?
  private let gate=AsyncWorkGate(limit:4)
  public init(reader: FileHandle, writer: FileHandle) { self.reader=reader; self.writer=writer }
  private func reply(_ data: Data, id: Int) async throws {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos:.userInitiated).async { [self] in
        lock.lock(); defer { lock.unlock() }
        do {
          guard !closed else { throw CancellationError() }
          try PluginChannel.write(["type":"reply","id":id,"payload":data.base64EncodedString()],to:writer,maximum:3_000_000)
          continuation.resume()
        } catch { continuation.resume(throwing:error) }
      }
    }
  }
  private func next() async throws -> [String:Any]? {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos:.userInitiated).async { [self] in
        do { continuation.resume(returning:try PluginChannel.read(from:reader,maximum:2_100_000)) }
        catch { continuation.resume(throwing:error) }
      }
    }
  }
  private func fail(_ error: Error) { lock.lock(); defer { lock.unlock() }; if failure==nil { failure=error } }
  private var currentFailure: Error? { lock.lock(); defer { lock.unlock() }; return failure }
  private func finish() { lock.lock(); closed=true; lock.unlock() }
  public func run(handler: @escaping @Sendable (PluginRPCRequest) async throws -> Data, cancel: @escaping @Sendable () -> Void, terminate: @escaping @Sendable () -> Void) async throws -> [String:Any] {
    try await withTaskCancellationHandler(operation: { try await withThrowingTaskGroup(of:Void.self) { group in
      defer { finish(); group.cancelAll(); cancel() }
      var expected=1
      do { while let frame=try await next() {
        if frame["type"] as? String=="result", Set(frame.keys)==["type","result"], let result=frame["result"] as? [String:Any] {
          try Task.checkCancellation()
          if let error=currentFailure { throw error }; return result
        }
        if frame["type"] as? String=="error", let error=frame["error"] as? String { throw MTVError.message(String(error.prefix(4096))) }
        let request=try PluginRPCRequest(frame:frame,expectedID:expected); expected += 1
        group.addTask { [self] in
          do {
            let payload=try await gate.run { try await handler(request) }
            try Task.checkCancellation(); try await reply(payload,id:request.id)
          } catch {
            if Task.isCancelled || error is CancellationError { return }
            do {
              try await reply(Data(PluginNetworkBroker.json(["error":String(error.localizedDescription.prefix(1024))]).utf8),id:request.id)
            } catch { fail(error); terminate(); cancel() }
          }
        }
      }
      throw MTVError.message("Async plugin exited without a result")
      } catch { terminate(); if Task.isCancelled { throw CancellationError() }; throw error }
    } },onCancel:{ terminate(); cancel() })
  }
}

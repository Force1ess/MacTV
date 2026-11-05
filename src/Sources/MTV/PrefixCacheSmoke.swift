import Foundation
import MTVCore

private final class PrefixFixtureBody: @unchecked Sendable {
  private let lock = NSLock()
  private var data: Data
  init(_ data: Data) { self.data = data }
  func snapshot() -> Data { lock.lock(); defer { lock.unlock() }; return data }
  func replace(_ value: Data) { lock.lock(); defer { lock.unlock() }; data = value }
}

extension UISmoke {
  static func prefixCacheSmoke() async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    let payload = Data((0..<524288).map { UInt8(truncatingIfNeeded: $0) })
    let body = PrefixFixtureBody(payload)
    let path = "/mtv-fixture/" + UUID().uuidString.lowercased() + "/fixture.mp4"
    let server = LoopbackMediaServer { candidate in
      guard candidate == path else { throw MTVError.message("测试路径未授权") }
      return .data(body.snapshot(), mime: "video/mp4")
    }
    defer { server.cancel() }
    do {
      let port = try await server.start()
      let request = try RemotePlaybackRequest.testingLoopback(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, headers: [:], referer: nil)
      let client = RemoteRangeClient(request); defer { client.cancel() }
      let header = try await client.fetch(offset: 0, count: 262144)
      await client.seedPrefix(header)
      let before = await client.statistics()
      let hit = try await client.fetch(offset: 128, count: 256)
      let after = await client.statistics()
      checks["prefixCacheExactBytesWithoutNetworkRequest"] = hit.data == payload.subdata(in: 128..<384)
        && before.requests == after.requests && after.prefixHits == 1
      let crossed = try await client.fetch(offset: 262000, count: 512)
      let crossing = await client.statistics()
      checks["prefixCacheCombinesOnlyMissingTail"] = crossed.data == payload.subdata(in: 262000..<262512)
        && crossing.requests == after.requests + 1 && crossing.received - after.received == 368
      let cancelledRead = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await client.fetch(offset: 0, count: 4)
      }
      do {
        _ = try await cancelledRead.value
        checks["prefixCacheCancelledTaskCannotReturnBytes"] = false
      } catch is CancellationError { checks["prefixCacheCancelledTaskCannotReturnBytes"] = true }
      catch { checks["prefixCacheCancelledTaskCannotReturnBytes"] = false }
      client.cancel()
      do { _ = try await client.fetch(offset: 0, count: 4); checks["prefixCacheClosedClientCannotReturnOldBytes"] = false }
      catch { checks["prefixCacheClosedClientCannotReturnOldBytes"] = true }
      let changedClient = RemoteRangeClient(request); defer { changedClient.cancel() }
      let original = try await changedClient.fetch(offset: 0, count: 262144)
      await changedClient.seedPrefix(original)
      body.replace(payload + Data([1]))
      do {
        _ = try await changedClient.fetch(offset: 262000, count: 512)
        checks["prefixCacheChangedLengthRejected"] = false
      } catch { checks["prefixCacheChangedLengthRejected"] = true }
      let failed = await changedClient.statistics()
      do {
        _ = try await changedClient.fetch(offset: 0, count: 4)
        checks["prefixCacheErrorInvalidatesPreviouslyCachedBytes"] = false
      } catch {
        let retried = await changedClient.statistics()
        checks["prefixCacheErrorInvalidatesPreviouslyCachedBytes"] = retried.requests == failed.requests + 1
          && retried.prefixHits == failed.prefixHits
      }
    } catch { checks["prefixCacheFixtureCompleted"] = false }
    return checks
  }
}

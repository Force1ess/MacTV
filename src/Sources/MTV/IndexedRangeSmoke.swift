import Foundation
import MTVCore

extension UISmoke {
  static func indexedRangeSmoke(output: URL) async -> [String: Bool] {
    guard let index = CommandLine.arguments.firstIndex(of: "--test-http-port"), index + 1 < CommandLine.arguments.count,
      let port = Int(CommandLine.arguments[index + 1]), (1024...65535).contains(port) else { return [:] }
    var checks: [String: Bool] = [:]
    func request(_ name: String) throws -> RemotePlaybackRequest {
      let query = name == "changed" || name == "clock" ? "?session=" + UUID().uuidString : ""
      return try RemotePlaybackRequest.testingLoopback(url: URL(string: "http://127.0.0.1:\(port)/mtv-fixture/\(name).mp4\(query)")!,
        headers: ["User-Agent": "MTV-HeaderFixture/1", "Referer": "https://fixture.invalid/"], referer: "https://fixture.invalid/")
    }
    do {
      let pooledFirst=RemoteRangeClient(try request("pool"),useSystemProxy:false)
      _ = try await pooledFirst.fetch(offset:0,count:32)
      pooledFirst.cancel(); _ = await pooledFirst.statistics()
      let pooledNext=RemoteRangeClient(try request("pool"),useSystemProxy:false); defer { pooledNext.cancel() }
      checks["indexedRangeNewPlaybackSurvivesPriorCancellation"] = try await pooledNext.fetch(offset:32,count:32).data.count == 32
      let valid = RemoteRangeClient(try request("redirect"),useSystemProxy:false)
      defer { valid.cancel() }
      let first = try await valid.fetch(offset: 0, count: 32)
      let second = try await valid.fetch(offset: 128, count: 16)
      checks["indexedRangeExactBytesAndLength"] = first.data.count == 32 && second.data.count == 16
        && first.totalLength > 1000 && first.totalLength == second.totalLength
      let minimal = RemoteRangeClient(try request("minimal"),useSystemProxy:false); defer { minimal.cancel() }
      _ = try await minimal.fetch(offset: 0, count: 2)
      checks["indexedRangeOptionalRepeatedMetadataAccepted"] = try await minimal.fetch(offset: 2, count: 2).data.count == 2
      let clock = RemoteRangeClient(try request("clock"),useSystemProxy:false); defer { clock.cancel() }
      _ = try await clock.fetch(offset: 0, count: 2)
      checks["indexedRangeWeakClockNotFalseVersionChange"] = try await clock.fetch(offset: 2, count: 2).data.count == 2
      for name in ["escape", "bad-range"] {
        let denied = RemoteRangeClient(try request(name),useSystemProxy:false); defer { denied.cancel() }
        do { _ = try await denied.fetch(offset: 0, count: 2); checks["indexedRangeRejects-" + name] = false }
        catch { checks["indexedRangeRejects-" + name] = true }
      }
      let changed = RemoteRangeClient(try request("changed"),useSystemProxy:false); defer { changed.cancel() }
      _ = try await changed.fetch(offset: 0, count: 2)
      do { _ = try await changed.fetch(offset: 2, count: 2); checks["indexedRangeChangedStrongTagRejected"] = false }
      catch { checks["indexedRangeChangedStrongTagRejected"] = true }
      let slow = RemoteRangeClient(try request("slow"),useSystemProxy:false)
      let work = Task { try await slow.fetch(offset: 0, count: 2) }
      try? await Task.sleep(for: .milliseconds(150))
      let time = Date(); slow.cancel()
      do { _ = try await work.value; checks["indexedRangeCancelReleasesAwaiter"] = false }
      catch { checks["indexedRangeCancelReleasesAwaiter"] = Date().timeIntervalSince(time) < 1 }
      let survivor=RemoteRangeClient(try request("movie"),useSystemProxy:false); defer { survivor.cancel() }
      checks["indexedRangeCancellationDoesNotInvalidateSharedTransport"] = try await survivor.fetch(offset:0,count:16).data.count == 16
      let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/stats")!)
      let stats = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
      let ports=stats["poolClientPorts"] as? [Int] ?? []
      checks["indexedRangeSequentialClientsReuseActualConnection"] = ports.count>=2 && Set(ports).count==1
      checks["indexedRangeNoCredentialsOrOutsideOriginRequests"] = stats["cookieRequests"] as? Int == 0
        && stats["authorizationRequests"] as? Int == 0 && stats["foreignRequests"] as? Int == 0
        && stats["missingHeaders"] as? Int == 0
      try data.write(to: output.appendingPathComponent("indexed-range-server.json"), options: .atomic)
    } catch { checks["indexedRangeFixtureFlow"] = false }
    return checks
  }
}

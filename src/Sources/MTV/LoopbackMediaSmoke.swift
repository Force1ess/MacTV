import Foundation
import MTVCore

extension UISmoke {
  static func loopbackMediaSmoke() async -> [String: Bool] {
    let nonce = UUID().uuidString.lowercased()
    let path = "/" + nonce + "/data.bin"
    let server = LoopbackMediaServer { candidate in
      guard candidate == path else { throw MTVError.message("内部路径未授权") }
      return .data(Data("MTV".utf8), mime: "application/octet-stream")
    }
    defer { server.cancel() }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil; configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 2
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    var checks: [String: Bool] = [:]
    do {
      let port = try await server.start()
      let url = URL(string: "http://127.0.0.1:\(port)" + path)!
      let (data, response) = try await session.data(from: url)
      checks["loopbackExactNonceRouteServed"] = data == Data("MTV".utf8) && (response as? HTTPURLResponse)?.statusCode == 200
      var request = URLRequest(url: url); request.setValue("bytes=1-1", forHTTPHeaderField: "Range")
      let (slice, partial) = try await session.data(for: request)
      checks["loopbackRelativeRangeCorrect"] = slice == Data("T".utf8) && (partial as? HTTPURLResponse)?.statusCode == 206
      for (name, headers, method) in [("Origin", ["Origin": "https://example.invalid"], "GET"),
        ("Credentials", ["Authorization": "test-only"], "GET"), ("Cookie", ["Cookie": "test-only=1"], "GET"),
        ("Method", [:], "POST")] {
        var bad = URLRequest(url: url); bad.httpMethod = method
        for (key, value) in headers { bad.setValue(value, forHTTPHeaderField: key) }
        let (_, result) = try await session.data(for: bad)
        checks["loopbackRejects" + name] = (result as? HTTPURLResponse)?.statusCode == 403
      }
      let (_, unknown) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/other/data.bin")!)
      checks["loopbackUnknownNonceDenied"] = (unknown as? HTTPURLResponse)?.statusCode == 403
      server.cancel()
      try? await Task.sleep(for: .milliseconds(100))
      do { _ = try await session.data(from: url); checks["loopbackClosedAfterCancel"] = false }
      catch { checks["loopbackClosedAfterCancel"] = true }
    } catch { checks["loopbackFixtureFlow"] = false }
    return checks
  }
}

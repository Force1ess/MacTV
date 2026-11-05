import Foundation
import Testing
@testable import MTVCore

struct PluginRequestHeadersTests {
  private final class Response: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "headers.example.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
      let sent = request.value(forHTTPHeaderField: "User-Agent") == "MTVOwnedHeaderFixture/1"
        && request.value(forHTTPHeaderField: "Accept") == "application/json, text/plain, */*"
      let code: Any = request.url?.path == "/boolean" ? true : request.url?.path == "/text" ? "secret-provider-string" : sent ? 32001 : 99999
      let body = try! JSONSerialization.data(withJSONObject: ["code": code, "message": "private-error-fixture", "token": "never-exported-fixture"])
      client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!, cacheStoragePolicy: .notAllowed)
      client?.urlProtocol(self, didLoad: body); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
  }
  private func manifest() throws -> PluginManifest {
    try JSONDecoder().decode(PluginManifest.self, from: Data(#"{"id":"test.headers","name":"Headers","version":"1","apiVersion":1,"entry":"plugin.js","domains":["headers.example.test"],"capabilities":["browse"],"requestUserAgent":"MTVOwnedHeaderFixture/1"}"#.utf8))
  }
  @Test func approvedHeadersAndNumericErrorsKeepResponseSecretsNative() throws {
    let manifest = try manifest()
    let broker = try PluginNetworkBroker(manifest: manifest, action: "browse", credential: nil)
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [Response.self]
    broker.useConfigurationForTesting(config)
    let reply = broker.request("https://headers.example.test/numeric", optionsJSON: "{}")
    let object = try #require(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
    #expect(object["status"] as? Int == 400)
    #expect(object["providerCode"] as? Int == 32001)
    #expect(object["body"] as? String == "")
    #expect(!reply.contains("private-error-fixture") && !reply.contains("never-exported-fixture"))
    for endpoint in ["boolean", "text"] {
      let reply = broker.request("https://headers.example.test/" + endpoint, optionsJSON: "{}")
      let object = try #require(JSONSerialization.jsonObject(with: Data(reply.utf8)) as? [String: Any])
      #expect(object["providerCode"] == nil)
    }
  }
  @Test func headerDeclarationCannotInjectNewHeaders() throws {
    var manifest = try manifest()
    try manifest.validate()
    for bad in ["", "safe\r\nCookie: fixture", String(repeating: "x", count: 513), "\u{7f}"] {
      manifest.requestUserAgent = bad
      #expect(throws: (any Error).self) { try manifest.validate() }
    }
  }
}

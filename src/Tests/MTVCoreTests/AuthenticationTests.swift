import Foundation
import Testing

@testable import MTVCore

struct AuthenticationTests {
  private func ticketManifest() throws -> PluginManifest {
    var value = try manifest()
    value.authentication!.credentialPaths.append("/redeem")
    value.authentication!.ticketExchange = PluginTicketExchange(
      sourcePath: "/poll", ticketPath: ["data", "members", "service_ticket"],
      endpoint: "https://auth.example.test/redeem", ticketParameter: "st",
      fixedQuery: ["lw": "scan"], confirmationBooleanPath: ["success"])
    return value
  }

  @Test func ticketExchangeIsScopedAndNeverLeaksThroughPublicPayload() throws {
    let value = try ticketManifest()
    try value.validate()
    let auth = value.authentication!
    let exchange = auth.ticketExchange!
    let body = Data(#"{"data":{"code":0,"members":{"service_ticket":"TEST_TICKET&extra=1"}}}"#.utf8)
    let url = try #require(
      try exchange.requestURL(
        body: body,
        source: URL(string: "https://auth.example.test/poll")!, authentication: auth))
    let query = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    #expect(query.count == 2)
    #expect(query.first { $0.name == "st" }?.value == "TEST_TICKET&extra=1")
    #expect(
      !String(decoding: try LoginResponseSanitizer.publicPayload(body), as: UTF8.self).contains(
        "TEST_TICKET"))
    #expect(
      try exchange.requestURL(
        body: body, source: URL(string: "https://evil.test/poll")!, authentication: auth) == nil)
    #expect(
      try exchange.requestURL(
        body: Data(#"{"data":{"code":false,"members":{"service_ticket":"TEST_TICKET"}}}"#.utf8),
        source: URL(string: "https://auth.example.test/poll")!, authentication: auth) == nil)
    for endpoint in [
      "https://evil.test/redeem", "http://auth.example.test/redeem",
      "https://auth.example.test/redeem?st=INJECTED", "https://auth.example.test:9999/redeem",
      "https://auth.example.test/undeclared",
    ] {
      var changed = exchange
      changed.endpoint = endpoint
      #expect(throws: (any Error).self) { try changed.validate(authentication: auth) }
    }
  }

  @Test func ticketCookieRequiresExplicitBooleanConfirmation() throws {
    let manifest = try ticketManifest()
    let capture = SessionCapture(manifest: manifest)
    let response = try #require(
      HTTPURLResponse(
        url: URL(string: "https://auth.example.test/redeem")!,
        statusCode: 200, httpVersion: nil,
        headerFields: [
          "Set-Cookie": "sid=TEST_ONLY; Domain=.example.test; Path=/; Secure; Max-Age=300"
        ]))
    for body in [#"{"success":false}"#, #"{"success":1}"#, #"{"data":{"code":0}}"#] {
      capture.beginRequest()
      capture.inspect(response: response)
      capture.confirm(body: Data(body.utf8))
      #expect(capture.value() == nil)
    }
    capture.beginRequest()
    capture.inspect(response: response)
    capture.confirm(body: Data(#"{"success":true}"#.utf8))
    #expect(capture.value()?.cookie == "sid=TEST_ONLY")
    capture.beginRequest()
    #expect(capture.value() == nil)
  }
  private func manifest() throws -> PluginManifest {
    try JSONDecoder().decode(
      PluginManifest.self,
      from: Data(
        #"{"id":"test.auth","name":"Auth test","version":"1","apiVersion":1,"entry":"plugin.js","domains":["api.example.test","auth.example.test"],"capabilities":["browse","login"],"authentication":{"issuerDomains":["auth.example.test"],"sessionDomains":["api.example.test"],"qrDomains":["auth.example.test"],"cookieNames":["sid"],"requiredCookieNames":["sid"],"challengePaths":["/qr"],"credentialPaths":["/poll"],"successCodePath":["data","code"],"successCode":0}}"#
          .utf8))
  }
  @Test func sessionOnlyGoesToExactAuthorizedHTTPSHost() throws {
    let manifest = try manifest()
    try manifest.validate()
    let session = PluginSession(
      pluginID: "test.auth", domains: ["api.example.test"], cookie: "sid=TEST_ONLY")
    try session.validate(for: manifest)
    #expect(session.cookieHeader(for: URL(string: "https://api.example.test/me")!) != nil)
    for address in [
      "https://auth.example.test/me", "http://api.example.test/me",
      "https://sub.api.example.test/me", "https://api.example.test.evil.test/me",
      "https://api.example.test:9999/me",
    ] {
      #expect(session.cookieHeader(for: URL(string: address)!) == nil)
    }
  }
  @Test func rejectsCrossPluginExpiredAndInjectedSessions() throws {
    let manifest = try manifest()
    let bad = [
      PluginSession(
        pluginID: "other.plugin", domains: ["api.example.test"], cookie: "sid=TEST_ONLY"),
      PluginSession(pluginID: "test.auth", domains: ["evil.test"], cookie: "sid=TEST_ONLY"),
      PluginSession(
        pluginID: "test.auth", domains: ["api.example.test"],
        cookie: "sid=TEST_ONLY\r\nInjected: yes"),
      PluginSession(
        pluginID: "test.auth", domains: ["api.example.test"], cookie: "sid=TEST_ONLY", expiresAt: 1),
    ]
    for session in bad { #expect(throws: (any Error).self) { try session.validate(for: manifest) } }
  }
  @Test func loginResponseDoesNotExposeRedirectOrRefreshSecrets() throws {
    let raw = Data(
      #"{"code":0,"secret":"TEST_SECRET","data":{"code":0,"message":"OK","url":"https://example.test/?sid=TEST_SECRET","refresh_token":"TEST_SECRET","timestamp":1}}"#
        .utf8)
    let data = try LoginResponseSanitizer.publicPayload(raw)
    let text = String(data: data, encoding: .utf8)!
    #expect(!text.contains("TEST_SECRET"))
    #expect(!text.contains("refresh_token"))
    #expect(text.contains("timestamp"))
  }
  @Test func qrMustUseDeclaredIssuerAndHaveBoundedLifetime() throws {
    let manifest = try manifest()
    func challenge(_ address: String) throws -> PluginLoginResponse {
      let object: [String: Any] = [
        "state": "waiting", "qrURL": address, "token": "TEST_TOKEN",
        "expiresAt": Date().timeIntervalSince1970 + 180,
      ]
      return try JSONDecoder().decode(
        PluginLoginResponse.self, from: JSONSerialization.data(withJSONObject: object))
    }
    try challenge("https://auth.example.test/qr?token=TEST_TOKEN").validateChallenge(for: manifest)
    for address in [
      "http://auth.example.test/qr", "https://auth.example.test.evil.test/qr", "file:///tmp/qr",
    ] {
      #expect(throws: (any Error).self) { try challenge(address).validateChallenge(for: manifest) }
    }
  }
  @Test func cookieCaptureRequiresServerSuccessAndAuthorizedDomain() throws {
    let manifest = try manifest()
    func capture(_ cookie: String, body: String, address: String = "https://auth.example.test/poll")
      -> PluginSession?
    {
      let box = SessionCapture(manifest: manifest)
      let response = HTTPURLResponse(
        url: URL(string: address)!, statusCode: 200, httpVersion: "HTTP/1.1",
        headerFields: ["Set-Cookie": cookie])!
      box.inspect(response: response)
      #expect(box.value() == nil)
      box.confirm(body: Data(body.utf8))
      return box.value()
    }
    let good = "sid=TEST_ONLY; Domain=.example.test; Path=/; Secure; HttpOnly; Max-Age=1800"
    #expect(capture(good, body: #"{"data":{"code":0}}"#)?.pluginID == "test.auth")
    #expect(capture(good, body: #"{"data":{"code":86101}}"#) == nil)
    #expect(capture(good, body: #"{"data":{"code":false}}"#) == nil)
    #expect(
      capture("sid=TEST_ONLY; Domain=.evil.test; Secure", body: #"{"data":{"code":0}}"#) == nil)
    #expect(capture("sid=TEST_ONLY; Domain=.example.test", body: #"{"data":{"code":0}}"#) == nil)
    #expect(
      capture(
        "sid=TEST_ONLY; Domain=.example.test; Path=/private; Secure", body: #"{"data":{"code":0}}"#)
        == nil)
    #expect(
      capture(good, body: #"{"data":{"code":0}}"#, address: "https://auth.example.test/qr") == nil)
  }
}

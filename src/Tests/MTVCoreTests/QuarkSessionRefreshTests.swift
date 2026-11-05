import Foundation
import Testing
@testable import MTVCore

struct QuarkSessionRefreshTests {
  @Test func legacySessionsReceiveOneStableIdentityWithoutExtendingTheirExpiry() throws {
    let store = PluginSessionStore(service:"fixture.identity." + UUID().uuidString)
    let legacy = PluginSession(pluginID:"fixture",domains:["example.test"],cookie:"fixture=value",expiresAt:9999999999,authIdentity:nil)
    defer { try? store.remove(pluginID:"fixture") }
    try store.save(legacy)
    let initial = try store.load(pluginID:"fixture"), repeated = try store.load(pluginID:"fixture")
    let first = try #require(initial), second = try #require(repeated)
    #expect(first.authIdentity != nil && first.authIdentity == second.authIdentity)
    #expect(first.expiresAt == legacy.expiresAt && first.savedAt == legacy.savedAt)
  }
  let now = Date().timeIntervalSince1970
  private func response(_ host: String = "drive.quark.cn", path: String = "/1/clouddrive/file/sort", status: Int = 200) -> HTTPURLResponse {
    HTTPURLResponse(url: URL(string: "https://\(host)\(path)")!, statusCode: status, httpVersion: "HTTP/1.1",
      headerFields: ["Set-Cookie":"__puus=refreshed-fixture; Domain=.quark.cn; Path=/; Max-Age=3600; Secure; HttpOnly"])!
  }
  @Test func refreshedCookieReplacesItsOwnExpiryInsteadOfKeepingOldMinimum() throws {
    let original = PluginSession(pluginID: "mtv.quark", domains: ["drive.quark.cn"], cookie: "__pus=fixture; __puus=old-fixture",
      expiresAt: now + 5, cookieExpiries: ["__pus":now+7200, "__puus":now+5])
    let refreshed = try #require(original.refreshingQuarkCookies(from: response(), now: now))
    #expect(refreshed.cookie.contains("__puus=refreshed-fixture"))
    #expect((refreshed.expiresAt ?? 0) > now + 3500)
    #expect(refreshed.cookieExpiries?["__pus"] == now + 7200)
    #expect(refreshed.authIdentity == original.authIdentity)
  }
  @Test func unrelatedOriginsErrorsAndUnknownLegacyExpiriesCannotExtendSession() throws {
    let legacy = PluginSession(pluginID: "mtv.quark", domains: ["drive.quark.cn"], cookie: "__pus=fixture", expiresAt: now + 5)
    #expect(legacy.refreshingQuarkCookies(from: response("example.com")) == nil)
    #expect(legacy.refreshingQuarkCookies(from: response(status: 401)) == nil)
    #expect(legacy.refreshingQuarkCookies(from: response(path: "/unrelated")) == nil)
    let refreshed = try #require(legacy.refreshingQuarkCookies(from: response()))
    #expect(refreshed.expiresAt == legacy.expiresAt)
  }
  @Test func lateResponsesDoNotUndoLogoutOrNewerLogin() throws {
    let service = "local.mtv.fixture.session-refresh." + UUID().uuidString
    let store = PluginSessionStore(service: service)
    let original = PluginSession(pluginID: "fixture", domains: ["example.com"], cookie: "a=1")
    let updated = PluginSession(pluginID: "fixture", domains: ["example.com"], cookie: "a=2")
    defer { try? store.remove(pluginID: "fixture") }
    try store.save(original)
    #expect(try store.replace(original, with: updated))
    #expect(try !store.replace(original, with: original))
    try store.remove(pluginID: "fixture")
    #expect(try !store.replace(updated, with: original))
    #expect(try store.load(pluginID: "fixture") == nil)
  }
}

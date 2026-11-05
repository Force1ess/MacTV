import Foundation
import Testing
@testable import MTVCore

struct NativeMediaSessionTests {
  @Test func quarkServiceFollowsRegionalRedirectsWithoutLeakingToOtherDriveHosts() throws {
    let first = URL(string: "https://video-play-c-sz.drive.quark.cn/movie")!
    let second = URL(string: "https://video-play-c-zb.drive.quark.cn/movie")!
    let session = PluginSession(pluginID: "mtv.quark", domains: ["drive.quark.cn"], cookie: "__pus=OWNED_FIXTURE")
    let base = try RemotePlaybackRequest(url: first, domains: ["quark.cn"], headers: [:], referer: nil)
    let exact = try base.authorizingMediaSession(session, approvedHost: first.host!)
    let service = try base.authorizingMediaSession(session, approvedHost: first.host!, quarkPlaybackService: true)
    #expect(!exact.permits(second))
    #expect(try service.nativeRequest(for: second).value(forHTTPHeaderField: "Cookie") == session.cookie)
    for address in ["https://drive.quark.cn/account", "https://other.drive.quark.cn/movie", "https://video-play-c-zb.drive.quark.cn.attacker.invalid/movie", "http://video-play-c-zb.drive.quark.cn/movie"] {
      #expect(!service.permits(URL(string: address)!))
    }
  }
  @Test func onlyExactApprovedFirstPartyHostGetsNativeSession() throws {
    let url = URL(string: "https://media.service.example/video?signature=private-fixture")!
    let original = try RemotePlaybackRequest(url: url, domains: ["service.example"], headers: [:], referer: nil)
    let session = PluginSession(pluginID: "test.provider", domains: ["service.example"], cookie: "OWNED_COOKIE=fixture-only")
    let scoped = try original.authorizingMediaSession(session, approvedHost: "media.service.example")
    #expect(!original.carriesNativeSession && scoped.requiresNativeLoader)
    #expect(scoped.headers["Cookie"] == nil && scoped.headers["cookie"] == nil)
    #expect(try scoped.nativeRequest(for: url).value(forHTTPHeaderField: "Cookie") == session.cookie)
    #expect(try original.nativeRequest(for: url).value(forHTTPHeaderField: "Cookie") == nil)
    for address in ["https://other.service.example/video", "https://media.service.example.evil.test/video",
      "https://media.service.example:8443/video", "http://media.service.example/video", "https://user:pass@media.service.example/video"] {
      let target = URL(string: address)!
      #expect(!scoped.permits(target))
      #expect(throws: (any Error).self) { try scoped.nativeRequest(for: target) }
    }
    #expect(!String(describing: scoped).contains("private-fixture"))
    #expect(!String(reflecting: scoped).contains("OWNED_COOKIE"))
    #expect(!String(reflecting: Mirror(reflecting: scoped)).contains("fixture-only"))
  }
  @Test func unrelatedExpiredOrInjectedCredentialsCannotBeAttached() throws {
    let request = try RemotePlaybackRequest(url: URL(string: "https://media.service.example/movie")!, domains: ["service.example"], headers: [:], referer: nil)
    for session in [PluginSession(pluginID: "test", domains: ["other.example"], cookie: "own=fixture"),
      PluginSession(pluginID: "test", domains: ["service.example"], cookie: "own=fixture", expiresAt: 1),
      PluginSession(pluginID: "test", domains: ["service.example"], cookie: "own=fixture\r\nX: injected")] {
      #expect(throws: (any Error).self) { try request.authorizingMediaSession(session, approvedHost: "media.service.example") }
    }
    let valid = PluginSession(pluginID: "test", domains: ["service.example"], cookie: "own=fixture")
    #expect(throws: (any Error).self) { try request.authorizingMediaSession(valid, approvedHost: "service.example") }
  }
  @Test func benchmarksCannotMixDifferentMediaAuthorizationPaths() {
    var before = PlaybackBenchmarkRecord(reference: "owned", variant: "before", trial: 0)
    var after = PlaybackBenchmarkRecord(reference: "owned", variant: "after", trial: 0)
    before.metadata["nativeMediaSessionHost"] = "none"
    after.metadata["nativeMediaSessionHost"] = "media.service.example"
    #expect(!PlaybackBenchmarkRecord.comparisonCompatible([before], [after]))
    before.metadata["nativeMediaSessionHost"] = "media.service.example"
    #expect(PlaybackBenchmarkRecord.comparisonCompatible([before], [after]))
  }
}

import Foundation
import Testing
@testable import MTVCore

struct MediaSessionApprovalStoreTests {
  @Test func serviceConsentSurvivesRegionalChangesAndCanBeRevoked() throws {
    let name = "test.media.service." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = MediaSessionApprovalStore(defaults: defaults)
    store.approveQuarkPlaybackService()
    #expect(store.permits(pluginID: "mtv.quark", host: "video-play-c-newregion.drive.quark.cn"))
    #expect(!store.permits(pluginID: "mtv.bilibili", host: FirstPartyMediaScope.quarkHost))
    #expect(!store.permits(pluginID: "mtv.quark", host: "drive.quark.cn"))
    store.revokeAll(pluginID: "mtv.quark")
    #expect(!store.permits(pluginID: "mtv.quark", host: "video-play-c-newregion.drive.quark.cn"))
  }
  @Test func regionalHostsRequireSeparateApprovalsAndSignoutRevokesEveryRegion() throws {
    let name = "test.media.regions." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = MediaSessionApprovalStore(defaults: defaults)
    let second = "video-play-c-zb.drive.quark.cn"
    try store.approve(pluginID: "mtv.quark", host: FirstPartyMediaScope.quarkHost)
    #expect(!store.permits(pluginID: "mtv.quark", host: second))
    try store.approve(pluginID: "mtv.quark", host: second)
    try store.approve(pluginID: "mtv.bilibili", host: second)
    store.revokeAll(pluginID: "mtv.quark")
    #expect(FirstPartyMediaScope.quarkHosts.allSatisfy { !store.permits(pluginID: "mtv.quark", host: $0) })
    #expect(store.permits(pluginID: "mtv.bilibili", host: second))
    #expect(!FirstPartyMediaScope.quarkHosts.contains(second + ".attacker.invalid"))
    #expect(!FirstPartyMediaScope.quarkHosts.contains("other.drive.quark.cn"))
  }
  @Test func approvalIsExactPerProviderAndRevocableWithoutCredentials() throws {
    let name = "test.media.approval." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let store = MediaSessionApprovalStore(defaults: defaults), host = FirstPartyMediaScope.quarkHost
    #expect(!store.permits(pluginID: "mtv.quark", host: host))
    try store.approve(pluginID: "mtv.quark", host: host)
    #expect(MediaSessionApprovalStore(defaults: defaults).permits(pluginID: "mtv.quark", host: host))
    #expect(!store.permits(pluginID: "mtv.bilibili", host: host))
    #expect(!store.permits(pluginID: "mtv.quark", host: "other.drive.quark.cn"))
    #expect(!store.permits(pluginID: "mtv.quark", host: "drive.quark.cn"))
    for invalid in ["*.drive.quark.cn", "https://" + host, host + "/path", "user@" + host] {
      #expect(throws: (any Error).self) { try store.approve(pluginID: "mtv.quark", host: invalid) }
    }
    store.revoke(pluginID: "mtv.quark", host: host)
    #expect(!store.permits(pluginID: "mtv.quark", host: host))
  }
}

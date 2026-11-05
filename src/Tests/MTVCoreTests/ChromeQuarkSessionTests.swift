import Foundation
import Testing
import CryptoKit
@testable import MTVCore
struct ChromeQuarkSessionTests {
  private func parse(_ cookies: [[String: Any]]) throws -> ChromeQuarkSessionImport {
    try JSONDecoder().decode(ChromeQuarkSessionImport.self, from: JSONSerialization.data(withJSONObject:
      ["schema": 1, "provider": "mtv.quark", "cookies": cookies]))
  }
  private func cookie(_ name: String = "__pus", _ value: String = "fixture", domain: String = ".quark.cn") -> [String: Any] {
    ["name": name, "value": value, "domain": domain, "path": "/", "hostOnly": false]
  }
  @Test func createsOnlyDriveScopedSessionWithoutExposingToOtherHosts() throws {
    let session = try parse([cookie(), cookie("__puus", "fixture2")]).session()
    #expect(session.pluginID == "mtv.quark" && session.domains == ["drive.quark.cn"])
    #expect(session.cookieHeader(for: URL(string: "https://drive.quark.cn/1/clouddrive/file/sort")!) != nil)
    #expect(session.cookieHeader(for: URL(string: "https://cdn.quark.cn/video")!) == nil)
  }
  @Test func rejectsOtherDomainsNamesInjectionAndConflictingCookies() throws {
    for list in [[cookie(domain: ".example.com")], [cookie("other", "fixture")],
      [cookie("__pus", "abc; injected=1")], [cookie(), cookie("__pus", "different")], [cookie("__uid", "only")]] {
      #expect(throws: Error.self) { try parse(list).session() }
    }
  }
  @Test func rejectsExpiredAndHostOnlyParentDomainCookies() throws {
    var expired = cookie(); expired["expirationDate"] = 1
    var parent = cookie(); parent["hostOnly"] = true
    #expect(throws: Error.self) { try parse([expired]).session(now: 2) }
    #expect(throws: Error.self) { try parse([parent]).session() }
  }
  @Test func extensionIdentityAndPermissionsMatchNativeAllowlist() throws {
    let root = TestProject.root
    let data = try Data(contentsOf: root.appendingPathComponent("src/browser-extension/manifest.json"))
    let manifest = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let encoded = try #require(manifest["key"] as? String)
    let key = try #require(Data(base64Encoded: encoded))
    let alphabet = Array("abcdefghijklmnop")
    let id = SHA256.hash(data: key).prefix(16).flatMap { [alphabet[Int($0 >> 4)], alphabet[Int($0 & 15)]] }
    #expect(String(id) == ChromeQuarkSessionImport.extensionID)
    #expect(Set(manifest["permissions"] as? [String] ?? []) == ["cookies", "nativeMessaging"])
    #expect(Set(manifest["host_permissions"] as? [String] ?? []) == ["https://drive.quark.cn/*", "https://pan.quark.cn/*", "https://api.bilibili.com/*", "https://www.bilibili.com/*"])
  }
}

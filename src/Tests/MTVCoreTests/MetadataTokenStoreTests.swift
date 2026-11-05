import Foundation
import Testing
@testable import MTVCore

struct MetadataTokenStoreTests {
  @Test func selectedPreferencesDomainControlsOnlyItsOwnRecord() throws {
    let name = "test.metadata." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: name))
    let other = try #require(UserDefaults(suiteName: name + ".other"))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    defer {
      defaults.removePersistentDomain(forName: name)
      other.removePersistentDomain(forName: name + ".other")
      try? FileManager.default.removeItem(at: root)
    }
    let store = MetadataTokenStore(defaults: defaults, root: root)
    let isolated = MetadataTokenStore(defaults: other, root: root)
    #expect(!store.isConfigured)
    try store.save(" fixture-token ")
    #expect(try store.load() == "fixture-token")
    #expect(!isolated.isConfigured)
    #expect(try isolated.load() == nil)
    #expect(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int == 0o700)
    let file = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
    #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
    #expect(throws: (any Error).self) { try store.save("invalid\nembedded") }
    #expect(try store.load() == "fixture-token")
    try store.remove()
    #expect(!store.isConfigured)
    #expect(try store.load() == nil)
  }
}

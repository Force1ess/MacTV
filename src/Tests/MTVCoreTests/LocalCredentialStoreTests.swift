import Darwin
import Foundation
import Testing
@testable import MTVCore

struct LocalCredentialStoreTests {
  @Test func localRecordsArePrivateAtomicAndSeparated() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = LocalCredentialStore(service: "test.a", root: root)
    let b = LocalCredentialStore(service: "test.b", root: root)
    try a.save(Data("first".utf8), account: "user")
    try b.save(Data("other".utf8), account: "user")
    try a.save(Data("replacement".utf8), account: "user")
    #expect(try a.load(account: "user") == Data("replacement".utf8))
    #expect(try b.load(account: "user") == Data("other".utf8))
    #expect(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int == 0o700)
    for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
      #expect(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
      #expect(!file.lastPathComponent.hasPrefix(".write-"))
    }
    try a.remove(account: "user")
    #expect(try a.load(account: "user") == nil)
    #expect(try b.load(account: "user") != nil)
  }
  @Test func rejectsSymlinksAndReadableByOthers() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LocalCredentialStore(service: "test", root: root)
    try store.save(Data("own".utf8), account: "user")
    let file = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    #expect(throws: (any Error).self) { try store.load(account: "user") }
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(at: file, withDestinationURL: root.appendingPathComponent("missing"))
    #expect(throws: (any Error).self) { try store.load(account: "user") }
    // Atomic replacement replaces the link, never writes through to its target.
    try store.save(Data("new".utf8), account: "user")
    #expect(try store.load(account: "user") == Data("new".utf8))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
  }
  @Test func keychainWritesAreDisabled() {
    #expect(throws: (any Error).self) { try PrivateKeychain(service: "test.no-keychain-writes").save(Data(), account: "user") }
  }
}

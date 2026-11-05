import Foundation
import Testing

@testable import MTVCore

struct SMBProfileTests {
  @Test func profilesPersistWithoutPasswordAndKeepIdentityWhenEdited() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("smb.json")
    let store = SMBProfileStore(file: file)
    var profile = try SMBProfile(
      address: "SMB://NAS.local/电影/家庭 影片", username: "", guest: true, rememberPassword: true)
    #expect(
      profile.address
        == "smb://nas.local/%E7%94%B5%E5%BD%B1/%E5%AE%B6%E5%BA%AD%20%E5%BD%B1%E7%89%87")
    #expect(!profile.rememberPassword && profile.username.isEmpty)
    try await store.upsert(profile)
    profile.address = try SMBProfile.canonicalAddress("nas.local/电影/新目录")
    try await store.upsert(profile)
    let cold = try await SMBProfileStore(file: file).load()
    #expect(cold == [profile])
    let json = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as! [String: Any]
    let values = json["profiles"] as! [[String: Any]]
    #expect(values[0]["password"] == nil)
    try await store.remove(profile.id)
    #expect(try await store.load().isEmpty)
  }
  @Test func credentialsAreBoundToProfileServerPortShareAndUsername() throws {
    let profile = try SMBProfile(
      address: "nas/Movies/Season 1", username: "viewer", guest: false, rememberPassword: true)
    let record = try SMBCredentialRecord(password: "SMB_FIXTURE_SECRET_ONLY", profile: profile)
    var folder = profile
    folder.address = try SMBProfile.canonicalAddress("nas/Movies/Season 2")
    #expect(try record.password(for: folder) == "SMB_FIXTURE_SECRET_ONLY")
    for address in ["other/Movies", "nas:1445/Movies", "nas/OtherShare"] {
      var changed = profile
      changed.address = try SMBProfile.canonicalAddress(address)
      #expect(!changed.sameAccount(as: profile))
      #expect(throws: (any Error).self) { try record.password(for: changed) }
    }
    let anotherID = try SMBProfile(
      address: profile.address, username: profile.username, guest: false, rememberPassword: true)
    #expect(throws: (any Error).self) { try record.password(for: anotherID) }
    var user = profile
    user.username = "another"
    #expect(throws: (any Error).self) { try record.password(for: user) }
    var optedOut = profile
    optedOut.rememberPassword = false
    #expect(
      try SMBCredentialStore(service: "local.mtv.never-read." + UUID().uuidString).load(
        for: optedOut) == nil)
  }
  @Test func invalidAndCorruptProfilesAreNotOverwritten() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("smb.json")
    let bad = Data("{broken".utf8)
    try bad.write(to: file)
    let store = SMBProfileStore(file: file)
    let profile = try SMBProfile(
      address: "nas/Movies", username: "", guest: true, rememberPassword: false)
    await #expect(throws: (any Error).self) { try await store.upsert(profile) }
    #expect(try Data(contentsOf: file) == bad)
    #expect(throws: (any Error).self) {
      try SMBProfile(
        address: "smb://user:secret@nas/Movies", username: "u", guest: false, rememberPassword: true
      )
    }
    #expect(throws: (any Error).self) {
      try SMBProfile(address: "nas/Movies", username: "", guest: false, rememberPassword: false)
    }
    #expect(throws: (any Error).self) {
      try SMBCredentialRecord(
        password: "bad\0secret",
        profile: SMBProfile(
          address: "nas/Movies", username: "u", guest: false, rememberPassword: true))
    }
  }
  @Test func oversizedEscapedCredentialFailsBeforeKeychainWrite() throws {
    let profile = try SMBProfile(address: "nas/Movies", username: "u", guest: false, rememberPassword: true)
    let record = try SMBCredentialRecord(password: String(repeating: "\u{1}", count: 4096), profile: profile)
    #expect(throws: (any Error).self) { try record.encodedData() }
  }
}

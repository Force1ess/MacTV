import Foundation
import Testing
@testable import MTVCore

struct SMBStaleMountTests {
  @Test func residualLocalDirectoryCannotBecomeAValidatedReadOrArtworkSource() throws {
    let mount = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Mounts/" + UUID().uuidString)
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: mount) }
    let marker = mount.appendingPathComponent("private-local.txt")
    try Data("Owned local sentinel; not a network volume".utf8).write(to: marker)
    let untrusted = MountedSMBShare(mount: mount, directory: mount, readOnly: true, signature: SMBMountSignature(fileSystemID: Data([1]), owner: 501))
    var read = false
    #expect(throws: SMBFailure.self) { try untrusted.withCurrentMount { read = true } }
    #expect(!read)
    #expect(throws: SMBFailure.self) { try ArtworkFileReader.read(marker, access: .verifiedSMB(untrusted)) }
    #expect(try Data(contentsOf: marker) == Data("Owned local sentinel; not a network volume".utf8))
  }
  @Test func invalidMountCannotReplaceAnExistingOfflineCatalogWithEmptyScan() async throws {
    let mount = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Mounts/" + UUID().uuidString)
    let cache = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: mount); try? FileManager.default.removeItem(at: cache) }
    let profile = try SMBProfile(address: "fixture.invalid/Movies", username: "", guest: true, rememberPassword: false)
    let raw = [MediaItem(id: "owned", title: "Codec fixture", url: mount.appendingPathComponent("Movie.mp4").absoluteString)]
    let items = try SMBMediaIdentity.remap(raw, profile: profile, mount: mount)
    let store = SMBLibraryIndexStore(root: cache)
    // The existing lower-level codec API serializes generated metadata, without claiming a mount.
    try await store.saveDetailed(items, profile: profile, mount: mount)
    let original = try Data(contentsOf: cache.appendingPathComponent(profile.id.uuidString.lowercased() + ".json"))
    let stale = MountedSMBShare(mount: mount, directory: mount, readOnly: true, signature: SMBMountSignature(fileSystemID: Data([1]), owner: 501))
    await #expect(throws: SMBFailure.self) { try await store.saveDetailed([], profile: profile, mount: mount, verifying: stale) }
    #expect(try Data(contentsOf: cache.appendingPathComponent(profile.id.uuidString.lowercased() + ".json")) == original)
    #expect(try await store.load(profile: profile)?.records.count == 1)
  }
}

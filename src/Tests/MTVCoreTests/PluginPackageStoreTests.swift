import Foundation
import Testing
@testable import MTVCore

struct PluginPackageStoreTests {
  func package(_ directory: URL, id: String = "dev.example.test", version: String = "1.0", domains: [String] = [], script: String = "throw new Error('must not execute during review');") throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let manifest: [String: Any] = ["id": id, "name": "External Test", "version": version, "apiVersion": 1,
      "entry": "plugin.js", "domains": domains, "capabilities": ["browse"]]
    try JSONSerialization.data(withJSONObject: manifest).write(to: directory.appendingPathComponent("manifest.json"))
    try Data(script.utf8).write(to: directory.appendingPathComponent("plugin.js"))
  }
  @Test func reviewDoesNotInstallAndApprovalCopiesReviewedBytesNotMutableSource() async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: parent) }
    let source = parent.appendingPathComponent("source"), store = PluginPackageStore(root: parent.appendingPathComponent("managed"))
    try package(source)
    try Data("Own test license notice".utf8).write(to: source.appendingPathComponent("LICENSE"))
    let original = try Data(contentsOf: source.appendingPathComponent("plugin.js"))
    let review = try await store.prepare(directory: source)
    #expect(try await store.installed().isEmpty)
    #expect(try await store.catalog().plugins.isEmpty)
    try Data("new source code".utf8).write(to: source.appendingPathComponent("plugin.js"))
    let installed = try await store.approve(review.id)
    let catalog = try await store.catalog()
    #expect(installed.enabled && catalog.plugins.count == 1)
    #expect(review.noticeNames == ["LICENSE"])
    #expect(try Data(contentsOf: catalog.plugins[0].directory.appendingPathComponent("LICENSE")) == Data("Own test license notice".utf8))
    #expect(try Data(contentsOf: catalog.plugins[0].directory.appendingPathComponent("plugin.js")) == original)
    #expect(try await PluginPackageStore(root: parent.appendingPathComponent("managed")).installed().map(\.id) == [installed.id])
  }
  @Test func disabledUpdatedRemovedAndChangedPermissionsCannotUseOldGrant() async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: parent) }
    let source = parent.appendingPathComponent("source"), store = PluginPackageStore(root: parent.appendingPathComponent("managed"))
    try package(source)
    let review = try await store.prepare(directory: source); _ = try await store.approve(review.id)
    let old = try await store.catalog().plugins[0]
    try await store.setEnabled(old.id, false)
    #expect(try await store.catalog().plugins.isEmpty)
    await #expect(throws: (any Error).self) { try await store.resolve(old) }
    try await store.setEnabled(old.id, true)
    let parked = parent.appendingPathComponent("parked-installed")
    try FileManager.default.moveItem(at: old.directory, to: parked)
    try FileManager.default.createSymbolicLink(at: old.directory, withDestinationURL: parked)
    await #expect(throws: (any Error).self) { try await store.resolve(old) }
    try FileManager.default.removeItem(at: old.directory)
    try FileManager.default.moveItem(at: parked, to: old.directory)
    try package(source, version: "2.0", domains: ["example.com"])
    let update = try await store.prepare(directory: source)
    #expect(update.replacingVersion == "1.0")
    _ = try await store.approve(update.id)
    await #expect(throws: (any Error).self) { try await store.resolve(old) }
    let current = try await store.catalog().plugins[0]
    let manifest = current.directory.appendingPathComponent("manifest.json")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifest.path)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: current.directory.appendingPathComponent("plugin.js").path)
    try package(current.directory, version: "2.0", domains: ["changed.invalid"])
    await #expect(throws: (any Error).self) { try await store.resolve(current) }
    #expect(try await store.catalog().plugins.isEmpty)
    try await store.remove(current.id)
    #expect(try await store.installed().isEmpty)
    #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("plugin.js").path))
  }
  @Test func rejectsReservedIdentitySymlinkAndChangedStageWithoutGrantingAnything() async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: parent) }
    let source = parent.appendingPathComponent("source"), managed = parent.appendingPathComponent("managed")
    let store = PluginPackageStore(root: managed)
    try package(source, id: "mtv.bilibili")
    await #expect(throws: (any Error).self) { try await store.prepare(directory: source) }
    try package(source, id: "local")
    await #expect(throws: (any Error).self) { try await store.prepare(directory: source) }
    try package(source)
    let script = source.appendingPathComponent("plugin.js"), outside = parent.appendingPathComponent("outside.js")
    try FileManager.default.moveItem(at: script, to: outside)
    try FileManager.default.createSymbolicLink(at: script, withDestinationURL: outside)
    await #expect(throws: (any Error).self) { try await store.prepare(directory: source) }
    try FileManager.default.removeItem(at: script); try package(source)
    let review = try await store.prepare(directory: source)
    let staged = managed.appendingPathComponent("staging/" + review.id.uuidString.lowercased() + "/plugin.js")
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staged.path)
    try Data("changed staged code".utf8).write(to: staged)
    await #expect(throws: (any Error).self) { try await store.approve(review.id) }
    #expect(try await store.installed().isEmpty)
    await store.cancel(review.id)
    #expect(!FileManager.default.fileExists(atPath: staged.path))
  }
  @Test func corruptRegistryIsNotSilentlyReplaced() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let managed = root.appendingPathComponent("managed"), source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
    let bad = Data("not JSON".utf8), index = managed.appendingPathComponent("installed.json")
    try bad.write(to: index); try package(source)
    let store = PluginPackageStore(root: managed)
    await #expect(throws: (any Error).self) { try await store.prepare(directory: source) }
    await #expect(throws: (any Error).self) { try await store.remove("dev.example.test") }
    #expect(try Data(contentsOf: index) == bad)
  }

  @Test func recoveryBacksUpRawRegistryAndRetainsCodeWithoutGrantingOldReceipts() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let managed = root.appendingPathComponent("managed"), source = root.appendingPathComponent("source")
    let store = PluginPackageStore(root: managed)
    try package(source)
    let initial = try await store.prepare(directory: source); _ = try await store.approve(initial.id)
    let old = try #require(try await store.catalog().plugins.first)
    try package(source, version: "2.0")
    let pending = try await store.prepare(directory: source)
    let index = managed.appendingPathComponent("installed.json"), bad = Data("raw damaged registry".utf8)
    try bad.write(to: index)
    let review = try await store.reviewRegistryRecovery()
    #expect(review.byteCount == bad.count && !review.reason.isEmpty)
    #expect(try Data(contentsOf: index) == bad)
    let backup = try review.writeBackup(in: managed.appendingPathComponent("RegistryRecovery"))
    #expect(try Data(contentsOf: backup.url) == bad)
    let permissions = try FileManager.default.attributesOfItem(atPath: backup.url.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    try await store.commitRegistryRecovery(backup)
    #expect(try await store.installed().isEmpty)
    #expect(FileManager.default.fileExists(atPath: old.directory.appendingPathComponent("plugin.js").path))
    #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("plugin.js").path))
    await #expect(throws: (any Error).self) { try await store.resolve(old) }
    await #expect(throws: (any Error).self) { try await store.approve(pending.id) }
    let fresh = try await store.prepare(directory: source); _ = try await store.approve(fresh.id)
    #expect(try await store.installed().first?.manifest.version == "2.0")
    #expect(try await store.catalog().plugins.first?.directory != old.directory)
  }
  @Test func recoveryRejectsChangedRegistryAndBackupFromAnotherStore() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let index = root.appendingPathComponent("installed.json"), bad = Data("damaged".utf8)
    try bad.write(to: index)
    let store = PluginPackageStore(root: root), review = try await store.reviewRegistryRecovery()
    let backup = try review.writeBackup(in: root.appendingPathComponent("RegistryRecovery"))
    let changed = Data("newer damaged contents".utf8)
    try changed.write(to: index)
    await #expect(throws: (any Error).self) { try await store.commitRegistryRecovery(backup) }
    #expect(try Data(contentsOf: index) == changed)
    let valid = Data(#"{"schema":1,"packages":[]}"#.utf8)
    try valid.write(to: index)
    await #expect(throws: (any Error).self) { try await store.commitRegistryRecovery(backup) }
    await #expect(throws: (any Error).self) { try await store.reviewRegistryRecovery() }
    #expect(try Data(contentsOf: index) == valid)
    let other = root.appendingPathComponent("other")
    try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    try bad.write(to: other.appendingPathComponent("installed.json"))
    let otherStore = PluginPackageStore(root: other)
    await #expect(throws: (any Error).self) { try await otherStore.commitRegistryRecovery(backup) }
    #expect(try Data(contentsOf: other.appendingPathComponent("installed.json")) == bad)
    #expect(try Data(contentsOf: backup.url) == bad)
  }
  @Test func missingModifiedOrSymlinkedBackupCannotResetRegistry() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let index = root.appendingPathComponent("installed.json"), bad = Data("invalid".utf8)
    try bad.write(to: index)
    let store = PluginPackageStore(root: root), review = try await store.reviewRegistryRecovery()
    let backup = try review.writeBackup(in: root.appendingPathComponent("backups"))
    try Data("changed".utf8).write(to: backup.url)
    await #expect(throws: (any Error).self) { try await store.commitRegistryRecovery(backup) }
    let missing = try review.writeBackup(in: root.appendingPathComponent("backups"))
    try FileManager.default.removeItem(at: missing.url)
    await #expect(throws: (any Error).self) { try await store.commitRegistryRecovery(missing) }
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("backups"))
    #expect(throws: (any Error).self) { try review.writeBackup(in: link) }
    #expect(try Data(contentsOf: index) == bad)
  }
  @Test func malformedEmptyAndUnsupportedRegistriesKeepExactOriginalBytes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = PluginPackageStore(root: root), index = root.appendingPathComponent("installed.json")
    let reservedManifest = Data(#"{"schema":1,"packages":[{"receipt":"5B1233D8-17B3-4932-BCF9-266BF2B63888","manifest":{"id":"local","name":"Old package","version":"1.0","apiVersion":1,"entry":"plugin.js","domains":[],"capabilities":["browse"]},"enabled":true,"installedAt":0}]}"#.utf8)
    for data in [Data(), Data(#"{"schema":2,"packages":[]}"#.utf8), reservedManifest] {
      try data.write(to: index)
      let review = try await store.reviewRegistryRecovery()
      let backup = try review.writeBackup(in: root.appendingPathComponent("backups"))
      try await store.commitRegistryRecovery(backup)
      #expect(try Data(contentsOf: backup.url) == data)
      #expect(try await store.installed().isEmpty)
    }
    let tooLarge = Data(repeating: 120, count: 1_048_577)
    try tooLarge.write(to: index)
    await #expect(throws: (any Error).self) { try await store.reviewRegistryRecovery() }
    #expect(try Data(contentsOf: index) == tooLarge)
  }
  @Test func recoveryRejectsRegistryLinksAndManagedDirectoryLinks() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let external = root.appendingPathComponent("outside.json"), bad = Data("invalid".utf8)
    try bad.write(to: external)
    let index = root.appendingPathComponent("installed.json")
    try FileManager.default.createSymbolicLink(at: index, withDestinationURL: external)
    let store = PluginPackageStore(root: root)
    await #expect(throws: (any Error).self) { try await store.reviewRegistryRecovery() }
    try FileManager.default.removeItem(at: index); try bad.write(to: index)
    let link = root.appendingPathComponent("linked-managed")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    let linked = PluginPackageStore(root: link)
    await #expect(throws: (any Error).self) { try await linked.reviewRegistryRecovery() }
    #expect(try Data(contentsOf: external) == bad)
    #expect(try Data(contentsOf: index) == bad)
  }
  @Test func danglingRegistryLinkIsAnErrorRatherThanAnEmptyInstallation() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let managed = root.appendingPathComponent("managed"), source = root.appendingPathComponent("source")
    try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
    try package(source)
    let target = root.appendingPathComponent("missing.json"), index = managed.appendingPathComponent("installed.json")
    try FileManager.default.createSymbolicLink(at: index, withDestinationURL: target)
    let store = PluginPackageStore(root: managed)
    await #expect(throws: (any Error).self) { try await store.installed() }
    await #expect(throws: (any Error).self) { try await store.prepare(directory: source) }
    await #expect(throws: (any Error).self) { try await store.reviewRegistryRecovery() }
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: index.path) == target.path)
    #expect(!FileManager.default.fileExists(atPath: target.path))
  }
}

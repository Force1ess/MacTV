import Foundation
import Testing
@testable import MTVCore

struct PlaybackHistoryRecoveryTests {
  private func environment() -> (PlaybackResumeStore, UserDefaults) {
    let scope = UUID()
    return (.isolated(scope: scope), UserDefaults(suiteName: "local.mtv.preview.resume-fixture." + scope.uuidString.lowercased())!)
  }
  @Test func corruptHistoryIsBackedUpExactlyWhileProgressAndOtherPreferencesStay() throws {
    let (store, defaults) = environment(); defer { store.removeTestDomain() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let damaged = Data("damaged history fixture".utf8)
    defaults.set(damaged, forKey: "watch-history.v1"); defaults.set("retained", forKey: "unrelated")
    store.save(42, for: "one", duration: 200)
    store.save(12, for: "one", source: "test.plugin", duration: 100)
    let review = try store.reviewHistoryReset()
    #expect(review.isDamaged && review.recordCount == nil)
    #expect(defaults.data(forKey: "watch-history.v1") == damaged)
    let backup = try review.writeBackup(in: root)
    let raw = try PropertyListSerialization.propertyList(from: Data(contentsOf: backup.url), format: nil) as? [String: Any]
    #expect(raw?["value"] as? Data == damaged)
    let permissions = try FileManager.default.attributesOfItem(atPath: backup.url.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o600)
    try store.commitHistoryReset(backup)
    #expect(try store.recent().isEmpty)
    #expect(defaults.object(forKey: "watch-history.v1") == nil)
    #expect(store.position(for: "one") == 42 && store.position(for: "one", source: "test.plugin") == 12)
    #expect(defaults.string(forKey: "unrelated") == "retained")
  }
  @Test func reviewCannotClearNewerHistoryAndKeepsItsOriginalBackup() throws {
    let (store, defaults) = environment(); defer { store.removeTestDomain() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let context = try PlaybackHistoryContext(mediaID: "one", sourceID: "local", title: "First", sourceTitle: "Library", librarySource: LibrarySourceSelection(path: "/tmp/library"))
    store.save(12, for: "one", duration: 100); try store.remember(context)
    let review = try store.reviewHistoryReset()
    #expect(review.recordCount == 1 && !review.isDamaged)
    let backup = try review.writeBackup(in: root)
    let second = try PlaybackHistoryContext(mediaID: "two", sourceID: "local", title: "Second", sourceTitle: "Library", librarySource: LibrarySourceSelection(path: "/tmp/library"))
    store.save(12, for: "two", duration: 100); try store.remember(second)
    let changed = defaults.data(forKey: "watch-history.v1")
    #expect(throws: (any Error).self) { try store.commitHistoryReset(backup) }
    #expect(defaults.data(forKey: "watch-history.v1") == changed)
    #expect(try store.recent().count == 2)
    #expect(FileManager.default.fileExists(atPath: backup.url.path))
  }
  @Test func missingChangedAndSymlinkedBackupsCannotAuthorizeReset() throws {
    let (store, defaults) = environment(); defer { store.removeTestDomain() }
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: parent) }
    let damaged = Data("broken".utf8); defaults.set(damaged, forKey: "watch-history.v1")
    let review = try store.reviewHistoryReset()
    let missing = try review.writeBackup(in: parent.appendingPathComponent("backups"))
    try FileManager.default.removeItem(at: missing.url)
    #expect(throws: (any Error).self) { try store.commitHistoryReset(missing) }
    let changed = try review.writeBackup(in: parent.appendingPathComponent("backups"))
    try Data("modified".utf8).write(to: changed.url)
    #expect(throws: (any Error).self) { try store.commitHistoryReset(changed) }
    let link = parent.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: parent.appendingPathComponent("backups"))
    #expect(throws: (any Error).self) { try review.writeBackup(in: link) }
    #expect(defaults.data(forKey: "watch-history.v1") == damaged)
  }
  @Test func wrongTypedAndOversizedValuesAreHandledWithoutSilentDeletion() throws {
    let (store, defaults) = environment(); defer { store.removeTestDomain() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: (any Error).self) { try store.reviewHistoryReset() }
    defaults.set("wrong type", forKey: "watch-history.v1")
    let review = try store.reviewHistoryReset(), backup = try review.writeBackup(in: root)
    try store.commitHistoryReset(backup)
    #expect(try store.recent().isEmpty)
    defaults.set(Data(repeating: 1, count: 1_048_576), forKey: "watch-history.v1")
    #expect(throws: (any Error).self) { try store.reviewHistoryReset() }
    #expect(defaults.data(forKey: "watch-history.v1")?.count == 1_048_576)
  }
}

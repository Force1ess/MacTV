import Foundation
import Testing

@testable import MTVCore

struct LibrarySourceTests {
  @Test func freshInstallHasNoImplicitDirectoryAndExplicitSkipWins() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let index = LibraryIndexStore(file: root.appendingPathComponent("index.json"))
    let file = root.appendingPathComponent("source.json")
    let store = LibrarySourceStore(file: file)
    #expect(try await store.resolve(legacyPath: nil, index: index) == nil)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    try await store.save(LibrarySourceSelection(path: nil))
    let cold = LibrarySourceStore(file: file)
    let selection = try await cold.resolve(legacyPath: "/should-not-be-imported", index: index)
    #expect(selection != nil && selection?.path == nil && selection?.origin == .chosen)
  }
  @Test func legacyPreferenceMigratesOnceAndNewChoiceWins() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let index = LibraryIndexStore(file: root.appendingPathComponent("index.json"))
    try await index.save(items: [], root: URL(fileURLWithPath: "/Volumes/OldIndex"))
    let store = LibrarySourceStore(file: root.appendingPathComponent("source.json"))
    let first = try await store.resolve(legacyPath: "/Volumes/ExplicitLegacy", index: index)
    #expect(first?.path == "/Volumes/ExplicitLegacy" && first?.origin == .legacyPreference)
    try await store.save(LibrarySourceSelection(path: "/Volumes/Chosen"))
    #expect(
      try await store.resolve(legacyPath: "/Volumes/ExplicitLegacy", index: index)?.path
        == "/Volumes/Chosen")
  }
  @Test func ownIndexMigrationPreservesUnavailableSourceAndIndexBytes() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("index.json")
    let index = LibraryIndexStore(file: file)
    try await index.save(items: [], root: URL(fileURLWithPath: "/Volumes/DisconnectedFilms"))
    let bytes = try Data(contentsOf: file)
    let source = root.appendingPathComponent("source.json")
    let store = LibrarySourceStore(file: source)
    let migrated = try await store.resolve(legacyPath: nil, index: index)
    #expect(migrated?.path == "/Volumes/DisconnectedFilms" && migrated?.origin == .existingIndex)
    #expect(try Data(contentsOf: file) == bytes)
    #expect(try await LibrarySourceStore(file: source).load() == migrated)
  }
  @Test func invalidSavedConfigurationIsNotReplacedByMigration() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("source.json")
    let broken = Data("{broken".utf8)
    try broken.write(to: file)
    let store = LibrarySourceStore(file: file)
    let index = LibraryIndexStore(file: root.appendingPathComponent("index.json"))
    await #expect(throws: (any Error).self) {
      try await store.resolve(legacyPath: "/Volumes/Other", index: index)
    }
    #expect(try Data(contentsOf: file) == broken)
    for path in ["Movies", "smb://nas/Movies", "/tmp/a\0b", "/tmp/a/../b"] {
      #expect(throws: (any Error).self) { try LibrarySourceSelection(path: path).validate() }
    }
    try await store.save(LibrarySourceSelection(path: "/Volumes/Chosen"))
    #expect(try await store.load()?.path == "/Volumes/Chosen")
  }
}

import Foundation
import Testing

@testable import MTVCore

struct ArtworkStoreTests {
  @Test func dataSurvivesNewStoreAndURLQueriesHaveIndependentKeys() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mtv-art-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = URL(string: "https://static.example.test/image.jpg?v=1")!
    let b = URL(string: "https://static.example.test/image.jpg?v=2")!
    try await ArtworkDiskStore(root: root).write(Data([1, 2, 3]), for: a)
    let reopened = ArtworkDiskStore(root: root)
    #expect(try await reopened.read(a) == Data([1, 2, 3]))
    #expect(try await reopened.read(b) == nil)
  }
  @Test func quotaEvictsOnlyOwnedEntriesAndRejectsOversizedData() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mtv-art-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let marker = root.appendingPathComponent("unrelated.txt")
    try Data("keep".utf8).write(to: marker)
    let store = ArtworkDiskStore(root: root, capacity: 5, itemLimit: 4)
    try await store.write(Data([1, 2, 3, 4]), for: URL(string: "https://example.test/a")!)
    try await store.write(Data([5, 6, 7, 8]), for: URL(string: "https://example.test/b")!)
    let cached = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "image" }
    #expect(cached.count == 1)
    #expect(try Data(contentsOf: marker) == Data("keep".utf8))
    await #expect(throws: (any Error).self) {
      try await store.write(
        Data(repeating: 1, count: 6), for: URL(string: "https://example.test/c")!)
    }
    await #expect(throws: (any Error).self) {
      try await store.read(URL(string: "https://user:secret@example.test/a")!)
    }
  }
}

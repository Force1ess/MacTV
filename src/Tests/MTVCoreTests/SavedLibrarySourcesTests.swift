import Foundation
import Testing
@testable import MTVCore

struct SavedLibrarySourcesTests {
  @Test func sourcesSurviveNewStoreAndDeduplicateWithoutRewritingCurrentSelection() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("sources.json")
    let store = SavedLibrarySourcesStore(file: file)
    let local = LibrarySourceSelection(path: "/Volumes/Films")
    let nas = LibrarySourceSelection(smbProfileID: UUID())
    let first = try await store.remember(local, title: "电影")
    _ = try await store.remember(nas, title: "客厅 NAS")
    let updated = try await store.remember(local, title: "影片硬盘")
    #expect(updated.count == 2 && updated[0].id == first[0].id && updated[0].title == "影片硬盘")
    let cold = try await SavedLibrarySourcesStore(file: file).load()
    #expect(cold == updated && cold[0].selection == local && cold[1].selection == nas)
    let bytes = try Data(contentsOf: file)
    #expect(!String(decoding: bytes, as: UTF8.self).contains("password"))
    #expect(try await store.remember(LibrarySourceSelection(path: nil), title: "无来源") == updated)
    #expect(try await store.remove(first[0].id).map(\.selection) == [nas])
  }
  @Test func corruptCatalogCannotBeOverwrittenByRememberOrRemove() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("sources.json")
    let original = Data("{broken".utf8)
    try original.write(to: file)
    let store = SavedLibrarySourcesStore(file: file)
    await #expect(throws: (any Error).self) { try await store.remember(LibrarySourceSelection(path: "/Movies"), title: "Movies") }
    await #expect(throws: (any Error).self) { try await store.remove(UUID()) }
    #expect(try Data(contentsOf: file) == original)
  }
  @Test func sourceCapacityAndInvalidTitlesPreservePreviousCatalog() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SavedLibrarySourcesStore(file: root.appendingPathComponent("sources.json"))
    for number in 0..<32 { _ = try await store.remember(LibrarySourceSelection(path: "/Films/\(number)"), title: "\(number)") }
    await #expect(throws: (any Error).self) { try await store.remember(LibrarySourceSelection(path: "/Extra"), title: "Extra") }
    await #expect(throws: (any Error).self) { try await store.remember(LibrarySourceSelection(path: "/Films/0"), title: "bad\nname") }
    #expect(try await store.load().count == 32)
    #expect(try await store.load()[0].title == "0")
  }
  @Test func eachLocalSourceRetainsItsOwnOfflineSnapshotAcrossSwitches() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("index.json")
    let a = root.appendingPathComponent("disk-a"), b = root.appendingPathComponent("disk-b")
    let filmA = a.appendingPathComponent("Film.A.mp4"), filmB = b.appendingPathComponent("Film.B.mp4")
    let first = LibraryIndexSnapshot(schema: 1, sourcePath: a.path, scannedAt: Date(timeIntervalSince1970: 100),
      items: [MediaItem(id: filmA.path, title: "A", url: filmA.absoluteString)])
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try JSONEncoder().encode(first).write(to: file)
    let store = LibraryIndexStore(file: file)
    #expect(try await store.load(root: a)?.items.first?.title == "A")
    #expect(try await store.save(items: [MediaItem(id: filmB.path, title: "B", url: filmB.absoluteString)], root: b,
      scannedAt: Date(timeIntervalSince1970: 200)))
    let cold = LibraryIndexStore(file: file)
    #expect(try await cold.load(root: a)?.items.first?.title == "A")
    #expect(try await cold.load(root: b)?.items.first?.title == "B")
    #expect(try await cold.savedSourcePath() == b.path)
    #expect(try await !cold.save(items: [], root: a, scannedAt: Date(timeIntervalSince1970: 150)))
    #expect(try await cold.save(items: first.items, root: a, scannedAt: Date(timeIntervalSince1970: 300)))
    #expect(try await LibraryIndexStore(file: file).load(root: b)?.items.first?.title == "B")
    #expect(!FileManager.default.fileExists(atPath: a.path) && !FileManager.default.fileExists(atPath: b.path))
  }
  @Test func archiveCapacityRefusesNewWriteWithoutEvictingOrReplacingSnapshots() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("index.json")
    let store = LibraryIndexStore(file: file)
    for number in 0...32 {
      #expect(try await store.save(items: [], root: root.appendingPathComponent("disk-\(number)"),
        scannedAt: Date(timeIntervalSince1970: Double(number))))
    }
    let original = try Data(contentsOf: file)
    await #expect(throws: (any Error).self) {
      try await store.save(items: [], root: root.appendingPathComponent("extra"),
        scannedAt: Date(timeIntervalSince1970: 40))
    }
    #expect(try Data(contentsOf: file) == original)
    #expect(try await LibraryIndexStore(file: file).load(root: root.appendingPathComponent("disk-0")) != nil)
    #expect(try await store.savedSourcePath() == root.appendingPathComponent("disk-32").path)
  }
}

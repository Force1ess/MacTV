import Foundation
import Testing

@testable import MTVCore

struct LibraryIndexTests {
  private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []
    func append(_ value: Int) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func snapshot() -> [Int] { lock.lock(); defer { lock.unlock() }; return values }
  }
  @Test func largeDefaultScanReportsBoundedProgressIncludingOfflineEntries() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for number in 0..<1005 {
      try Data().write(to: root.appendingPathComponent("Film.\(number).mp4"))
    }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Offline.mp4"),
      withDestinationURL: root.appendingPathComponent("missing/Film.mp4"))
    let log = ProgressLog()
    let result = try LibraryScanner.scanResult(root: root, progress: { log.append($0) })
    #expect(!result.limited && result.items.count == 1005 && result.unavailableCount == 1)
    #expect(result.unavailableItems.count == 1)
    #expect(log.snapshot() == Array(stride(from: 0, through: 1000, by: 100)) + [1006])
  }
  @Test func coldStoreLoadsOfflineWithoutReadingMediaAndScopesSource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let media = root.appendingPathComponent("media")
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    try Data().write(to: media.appendingPathComponent("Test.2024.mp4"))
    let files = try LibraryScanner.scan(root: media)
    for item in files {
      #expect(item.id.hasPrefix(media.standardizedFileURL.path + "/"))
      #expect(URL(string: item.url!)!.standardizedFileURL.path == item.id)
      #expect(item.source == "local" && !item.isFolder && !item.isLibraryCollection)
      #expect(item.metadataAttribution == nil)
    }
    let index = root.appendingPathComponent("index.json")
    let store = LibraryIndexStore(file: index)
    #expect(try await store.save(items: files, root: media))
    try FileManager.default.removeItem(at: media)
    let cold = LibraryIndexStore(file: index)
    let loaded = try await cold.load(root: media)
    #expect(loaded?.items == files)
    #expect(try await cold.load(root: root.appendingPathComponent("other")) == nil)
    #expect(throws: (any Error).self) { try LibraryScanner.scan(root: media) }
    #expect(try await cold.load(root: media)?.items.count == 1)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    let empty = try LibraryScanner.scanResult(root: media)
    #expect(!empty.limited && empty.items.isEmpty)
    #expect(try await cold.save(items: empty.items, root: media))
    #expect(try await cold.load(root: media)?.items.isEmpty == true)
  }
  @Test func rejectsOutsidePathsAndLateWritesAcrossSources() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = LibraryIndexStore(file: root.appendingPathComponent("index.json"))
    let first = root.appendingPathComponent("first")
    let second = root.appendingPathComponent("second")
    let outside = root.appendingPathComponent("outside.mp4")
    let foreign = MediaItem(id: outside.path, title: "Invalid", url: outside.absoluteString)
    await #expect(throws: (any Error).self) { try await store.save(items: [foreign], root: first) }
    #expect(
      try await store.save(items: [], root: second, scannedAt: Date(timeIntervalSince1970: 200)))
    #expect(
      try await !store.save(items: [], root: first, scannedAt: Date(timeIntervalSince1970: 100)))
    #expect(try await store.load(root: second) != nil)
  }
  @Test func corruptDerivedCacheRequiresSuccessfulRebuild() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("index.json")
    let bytes = Data("{broken".utf8)
    try bytes.write(to: file)
    let store = LibraryIndexStore(file: file)
    await #expect(throws: (any Error).self) { try await store.load(root: root) }
    #expect(try Data(contentsOf: file) == bytes)
    #expect(try await store.save(items: [], root: root))
    #expect(try await store.load(root: root)?.schema == 1)
    #expect((try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) < 1000)
  }
  @Test func scannerDistinguishesExactLimitFromTruncatedResult() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("One.2024.mp4"))
    #expect(try !LibraryScanner.scanResult(root: root, limit: 1).limited)
    try Data().write(to: root.appendingPathComponent("Two.2025.mp4"))
    let limited = try LibraryScanner.scanResult(root: root, limit: 1)
    #expect(limited.limited && limited.items.count == 1)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Offline.mp4"),
      withDestinationURL: root.appendingPathComponent("unmounted-volume/film.mp4"))
    let incomplete = try LibraryScanner.scanResult(root: root)
    #expect(incomplete.unavailableCount == 1 && incomplete.items.count == 2)
    let offline = incomplete.unavailableItems[0]
    let old = MediaItem(id: offline.id, title: "Previous description", url: offline.url)
    let merged = incomplete.catalogItems(preserving: [old])
    #expect(merged.count == 3)
    #expect(merged.first(where: { $0.id == offline.id })?.title == "Previous description")
    #expect(merged.first(where: { $0.id == offline.id })?.localMetadata?.sourceReachable == false)
  }
}

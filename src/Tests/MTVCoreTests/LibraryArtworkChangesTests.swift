import Foundation
import Testing
@testable import MTVCore

struct LibraryArtworkChangesTests {
  @Test func tracksSamePathPosterAndBackdropButIgnoresNFOOnlyEdits() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let media = root.appendingPathComponent("Film.mp4"), poster = root.appendingPathComponent("poster.jpg"), fanart = root.appendingPathComponent("fanart.jpg")
    try Data().write(to: media); try Data("red".utf8).write(to: poster)
    let first = try LibraryScanner.scanResult(root: root)
    let warm = try LibraryScanner.scanResult(root: root, previous: first.incremental)
    func changes(_ before: LibraryScanResult, _ after: LibraryScanResult) -> Set<URL> {
      LibraryArtworkChanges.changed(previous: before.incremental, current: after.incremental, oldItems: before.items, newItems: after.items)
    }
    #expect(changes(first, warm).isEmpty)
    try Data("blue".utf8).write(to: poster)
    let replaced = try LibraryScanner.scanResult(root: root, previous: warm.incremental)
    #expect(changes(warm, replaced) == [poster.standardizedFileURL])
    try Data("green".utf8).write(to: fanart)
    let backdrop = try LibraryScanner.scanResult(root: root, previous: replaced.incremental)
    #expect(changes(replaced, backdrop) == [fanart.standardizedFileURL])
    try Data("<movie><title>New title</title></movie>".utf8).write(to: root.appendingPathComponent("Film.nfo"))
    let metadata = try LibraryScanner.scanResult(root: root, previous: backdrop.incremental)
    #expect(changes(backdrop, metadata).isEmpty)
    #expect(LibraryArtworkChanges.changed(previous: backdrop.incremental, current: metadata.incremental,
      oldItems: backdrop.items, newItems: metadata.items, force: true) == Set([poster.standardizedFileURL] + LocalArtworkCandidates.backdrops(in: root).map(\.standardizedFileURL)))
    try FileManager.default.removeItem(at: poster)
    let removed = try LibraryScanner.scanResult(root: root, previous: metadata.incremental)
    #expect(changes(metadata, removed) == [poster.standardizedFileURL])
  }
  @Test func artworkFromUnusableMetadataIsTrackedAndNonFileReferencesAreExcluded() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("Film.mp4"))
    try Data("<movie>broken".utf8).write(to: root.appendingPathComponent("Film.nfo"))
    let poster = root.appendingPathComponent("poster.jpg")
    try Data("red".utf8).write(to: poster)
    let first = try LibraryScanner.scanResult(root: root)
    let warm = try LibraryScanner.scanResult(root: root, previous: first.incremental)
    #expect(first.incremental?.manifest.files.isEmpty == true)
    #expect(LibraryArtworkChanges.changed(previous: first.incremental, current: warm.incremental, oldItems: first.items, newItems: warm.items).isEmpty)
    let remote = MediaItem(id: "remote", title: "Remote", poster: "https://fixture.invalid/poster.jpg")
    let localReference = MediaItem(id: "cache", title: "Cache", poster: "mtv-artwork://fixture/reference")
    #expect(LibraryArtworkChanges.localURLs(in: [remote, localReference]).isEmpty)
  }
}

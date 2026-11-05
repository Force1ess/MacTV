import Foundation
import Testing
@testable import MTVCore

struct LocalArtworkCandidatesTests {
  @Test func formatsUseSpecificityThenStableExtensionPriority() {
    let root = URL(fileURLWithPath: "/tmp/movies"), file = URL(fileURLWithPath: "/tmp/movies/Film.mp4")
    let urls = LocalArtworkCandidates.posters(for: file)
    #expect(Array(urls.prefix(4)).map(\.lastPathComponent) == ["Film.jpg", "Film.jpeg", "Film.png", "Film.webp"])
    #expect(urls.firstIndex(of: root.appendingPathComponent("Film-poster.png"))! < urls.firstIndex(of: root.appendingPathComponent("poster.jpg"))!)
    #expect(LocalArtworkCandidates.backdrops(in: root).map(\.lastPathComponent) == ["fanart.jpg", "fanart.jpeg", "fanart.png", "fanart.webp"])
  }
  @Test func newPosterFormatsRefreshWarmAndColdIndexesWithoutRewritingMedia() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("Film.mp4"), png = root.appendingPathComponent("poster.png"), jpeg = root.appendingPathComponent("poster.jpeg")
    try Data("media unchanged".utf8).write(to: file)
    try Data("<movie><title>Film</title></movie>".utf8).write(to: root.appendingPathComponent("Film.nfo"))
    let first = try LibraryScanner.scanResult(root: root)
    try Data("png fixture".utf8).write(to: png)
    let added = try LibraryScanner.scanResult(root: root, previous: first.incremental)
    #expect(added.items.first?.poster == png.absoluteString && added.reusedCount == 0)
    let warm = try LibraryScanner.scanResult(root: root, previous: added.incremental)
    #expect(warm.reusedCount == 1 && warm.nfoReadCount == 0)
    let index = LibraryIndexStore(file: root.appendingPathComponent("owned-index.json"))
    try await index.save(items: warm.items, root: root, incremental: warm.incremental?.manifest)
    let snapshot = try await LibraryIndexStore(file: index.file).load(root: root)
    let cold = try LibraryScanner.scanResult(root: root, previous: snapshot?.incrementalState)
    #expect(cold.reusedCount == 1)
    try Data("jpeg fixture".utf8).write(to: jpeg)
    let preferred = try LibraryScanner.scanResult(root: root, previous: cold.incremental)
    #expect(preferred.items.first?.poster == jpeg.absoluteString)
    try FileManager.default.removeItem(at: jpeg)
    let removed = try LibraryScanner.scanResult(root: root, previous: preferred.incremental)
    #expect(removed.items.first?.poster == png.absoluteString)
    #expect(try Data(contentsOf: file) == Data("media unchanged".utf8))
  }
  @Test func seriesFormatsAndNonJPGBackdropVersionsAreTracked() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), season = root.appendingPathComponent("Show/Season 1")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: season, withIntermediateDirectories: true)
    let show = season.deletingLastPathComponent(), poster = show.appendingPathComponent("poster.webp")
    try Data().write(to: season.appendingPathComponent("Show.S01E01.mp4"))
    try Data("<tvshow><title>Show</title></tvshow>".utf8).write(to: show.appendingPathComponent("tvshow.nfo"))
    try Data("webp fixture".utf8).write(to: poster)
    let first = try LibraryScanner.scanResult(root: root)
    #expect(first.items.first?.localMetadata?.seriesPoster == poster.absoluteString)
    let fanart = show.appendingPathComponent("fanart.png")
    try Data("red".utf8).write(to: fanart)
    let second = try LibraryScanner.scanResult(root: root, previous: first.incremental)
    #expect(LibraryArtworkChanges.changed(previous: first.incremental, current: second.incremental, oldItems: first.items, newItems: second.items) == [fanart.standardizedFileURL])
  }
}

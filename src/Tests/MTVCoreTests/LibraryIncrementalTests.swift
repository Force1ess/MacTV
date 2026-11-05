import Foundation
import Darwin
import Testing
@testable import MTVCore

struct LibraryIncrementalTests {
  func movie(_ root: URL, _ name: String, _ title: String) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent(name + ".mp4"))
    try nfo(root.appendingPathComponent(name + ".nfo"), title)
  }
  func nfo(_ url: URL, _ title: String) throws {
    try Data("<movie><title>\(title)</title></movie>".utf8).write(to: url)
  }
  @Test func reusesUnchangedMetadataAndDetectsSameSizeSameMtimeEditsAndRenames() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try movie(root, "A", "One"); try movie(root, "B", "Two")
    let first = try LibraryScanner.scanResult(root: root)
    #expect(first.nfoReadCount == 2 && first.reusedCount == 0)
    let warm = try LibraryScanner.scanResult(root: root, previous: first.incremental)
    #expect(warm.reusedCount == 2 && warm.nfoReadCount == 0 && warm.items == first.items)
    let sidecar = root.appendingPathComponent("A.nfo")
    var attributes = stat()
    #expect(sidecar.path.withCString { lstat($0, &attributes) } == 0)
    let times = [attributes.st_atimespec, attributes.st_mtimespec]
    try nfo(sidecar, "New")
    let restored = times.withUnsafeBufferPointer { buffer in sidecar.path.withCString { utimensat(AT_FDCWD, $0, buffer.baseAddress, 0) } }
    #expect(restored == 0)
    let changed = try LibraryScanner.scanResult(root: root, previous: warm.incremental)
    let oldStamp = first.incremental?.manifest.dependencies.first { $0.path == sidecar.path }?.target
    let newStamp = changed.incremental?.manifest.dependencies.first { $0.path == sidecar.path }?.target
    #expect(oldStamp?.size == newStamp?.size && oldStamp?.modifiedSeconds == newStamp?.modifiedSeconds && oldStamp?.modifiedNanos == newStamp?.modifiedNanos)
    #expect(changed.reusedCount == 1 && changed.nfoReadCount == 1)
    #expect(changed.items.first { $0.id.hasSuffix("/A.mp4") }?.title == "New")
    try FileManager.default.moveItem(at: root.appendingPathComponent("B.mp4"), to: root.appendingPathComponent("C.mp4"))
    try FileManager.default.moveItem(at: root.appendingPathComponent("B.nfo"), to: root.appendingPathComponent("C.nfo"))
    let renamed = try LibraryScanner.scanResult(root: root, previous: changed.incremental)
    #expect(renamed.reusedCount == 1 && renamed.items.contains { $0.id.hasSuffix("/C.mp4") })
    #expect(!renamed.items.contains { $0.id.hasSuffix("/B.mp4") })
  }
  @Test func coldIndexRetainsReuseAndRejectsBadReferencesWithoutOverwriting() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let media = root.appendingPathComponent("films")
    try movie(media, "A", "One")
    let store = LibraryIndexStore(file: root.appendingPathComponent("index.json"))
    let first = try LibraryScanner.scanResult(root: media)
    try await store.save(items: first.items, root: media)
    #expect(try await store.load(root: media)?.incrementalState == nil)
    try await store.save(items: first.items, root: media, incremental: first.incremental?.manifest)
    let cold = try await LibraryIndexStore(file: root.appendingPathComponent("index.json")).load(root: media)
    let warm = try LibraryScanner.scanResult(root: media, previous: cold?.incrementalState)
    #expect(warm.reusedCount == 1 && warm.nfoReadCount == 0)
    let original = try Data(contentsOf: root.appendingPathComponent("index.json"))
    let bad = LibraryIncrementalManifest(schema: 1, dependencies: [], files: [first.items[0].id: [999]])
    await #expect(throws: (any Error).self) { try await store.save(items: first.items, root: media, incremental: bad) }
    #expect(try Data(contentsOf: root.appendingPathComponent("index.json")) == original)
  }
  @Test func sharedShowAndPosterChangesInvalidateEpisodesAndNASReuseStaysMountScoped() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try movie(root, "Movie", "Movie")
    let show = root.appendingPathComponent("Show"), season = show.appendingPathComponent("Season 1")
    try FileManager.default.createDirectory(at: season, withIntermediateDirectories: true)
    for number in 1...2 { try Data().write(to: season.appendingPathComponent("Show.S01E0\(number).mp4")) }
    try nfo(show.appendingPathComponent("tvshow.nfo"), "Old Show")
    let first = try LibraryScanner.scanResult(root: root)
    let profile = try SMBProfile(address: "fixture.invalid/Films", username: "", guest: true, rememberPassword: false)
    let mapped = try first.withSMBIdentity(profile: profile, mount: root)
    let warm = try LibraryScanner.scanResult(root: root, previous: mapped.incremental)
    #expect(warm.reusedCount == 3 && warm.nfoReadCount == 0)
    try nfo(show.appendingPathComponent("tvshow.nfo"), "New Show")
    let changed = try LibraryScanner.scanResult(root: root, previous: warm.incremental)
    #expect(changed.reusedCount == 1 && changed.items.filter { $0.localMetadata?.seriesTitle == "New Show" }.count == 2)
    try Data([1, 2, 3]).write(to: show.appendingPathComponent("poster.jpg"))
    let poster = try LibraryScanner.scanResult(root: root, previous: changed.incremental)
    #expect(poster.reusedCount == 1 && poster.items.filter { $0.localMetadata?.seriesPoster != nil }.count == 2)
    let elsewhere = root.appendingPathComponent("Another Root")
    try movie(elsewhere, "A", "Elsewhere")
    let other = try LibraryScanner.scanResult(root: elsewhere, previous: poster.incremental)
    #expect(other.reusedCount == 0 && other.items[0].title == "Elsewhere")
  }
  @Test func malformedReadsAreNotMemoizedAndMidScanChangesCannotCommit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try movie(root, "A", "One")
    let sidecar = root.appendingPathComponent("A.nfo")
    try Data("<movie><title>".utf8).write(to: sidecar)
    let first = try LibraryScanner.scanResult(root: root)
    let second = try LibraryScanner.scanResult(root: root, previous: first.incremental)
    #expect(second.reusedCount == 0 && second.nfoReadCount == 1)
    try nfo(sidecar, "One")
    let good = try LibraryScanner.scanResult(root: root)
    let unrelated = try LibraryScanner.scanResult(root: root, previous: good.incremental, progress: { count in
      if count == 1 { try? Data("note".utf8).write(to: root.appendingPathComponent("notes.txt")) }
    })
    #expect(unrelated.reusedCount == 1 && unrelated.nfoReadCount == 0)
    let media = root.appendingPathComponent("A.mp4")
    let growing = try LibraryScanner.scanResult(root: root, previous: good.incremental, progress: { count in
      if count == 1 { try? Data([0, 1]).write(to: media) }
    })
    #expect(growing.items.count == 1 && growing.incremental?.manifest.files[media.path] == nil)
    #expect(throws: (any Error).self) {
      try LibraryScanner.scanResult(root: root, previous: good.incremental, progress: { count in
        if count == 1 { try? Data("<movie><title>Changed</title></movie>".utf8).write(to: sidecar) }
      })
    }
  }
  @Test func symlinkBoundaryAndNewSidecarsRemainObservable() throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = parent.appendingPathComponent("films")
    defer { try? FileManager.default.removeItem(at: parent) }
    try movie(root, "A", "Allowed")
    let sidecar = root.appendingPathComponent("A.nfo"), outside = parent.appendingPathComponent("outside.nfo")
    try FileManager.default.removeItem(at: sidecar)
    try nfo(outside, "Outside secret")
    try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: outside)
    let guarded = try LibraryScanner.scanResult(root: root, allowedResolvedRoot: root)
    let warm = try LibraryScanner.scanResult(root: root, allowedResolvedRoot: root, previous: guarded.incremental)
    #expect(warm.reusedCount == 1 && warm.nfoReadCount == 0 && warm.items[0].title != "Outside secret")
    let inside = root.appendingPathComponent("inside.nfo")
    try nfo(inside, "Allowed")
    try FileManager.default.removeItem(at: sidecar)
    try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: inside)
    let changed = try LibraryScanner.scanResult(root: root, allowedResolvedRoot: root, previous: warm.incremental)
    #expect(changed.reusedCount == 0 && changed.nfoReadCount == 1 && changed.items[0].title == "Allowed")
    #expect(throws: (any Error).self) {
      try LibraryScanner.scanResult(root: root, allowedResolvedRoot: root, previous: changed.incremental, progress: { count in
        if count == 1 { try? Data("<movie><title>New</title></movie>".utf8).write(to: root.appendingPathComponent("movie.nfo")) }
      })
    }
  }
  @Test func parserUpgradeReclassifiesOldGalleryCacheThenAllowsWarmReuse() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("gallery-version-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("爆炸")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data().write(to: folder.appendingPathComponent("[Group][Example Show][Explosion][01][1080P].mkv"))
    let first = try LibraryScanner.scanResult(root: root)
    let incremental = try #require(first.incremental)
    var legacyManifest = incremental.manifest
    legacyManifest.metadataParserVersion = 4
    var stale = try #require(first.items.first)
    stale.localMetadata?.isExtra = false
    let legacy = LibraryIncrementalState(root: root, items: [stale], manifest: legacyManifest)
    let upgraded = try LibraryScanner.scanResult(root: root, previous: legacy)
    #expect(upgraded.reusedCount == 0 && upgraded.items.first?.localMetadata?.isExtra == true)
    #expect(upgraded.incremental?.manifest.metadataParserVersion == 6)
    let warm = try LibraryScanner.scanResult(root: root, previous: upgraded.incremental)
    #expect(warm.reusedCount == 1 && warm.items.first?.localMetadata?.isExtra == true)
  }

}

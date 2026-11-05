import Foundation
import Testing
@testable import MTVCore

struct MetadataReadFailureTests {
  func movie(_ folder: URL, name: String, title: String) throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data().write(to: folder.appendingPathComponent(name + ".mp4"))
    try Data("<movie><title>\(title)</title></movie>".utf8).write(to: folder.appendingPathComponent(name + ".nfo"))
  }
  @Test func partialFailureKeepsDescriptionsAcrossColdIndexAndRepairOrRemovalWins() async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), root = parent.appendingPathComponent("films")
    defer { try? FileManager.default.removeItem(at: parent) }
    try movie(root, name: "A", title: "Original A"); try movie(root, name: "B", title: "Original B")
    let old = try LibraryScanner.scanResult(root: root)
    let a = root.appendingPathComponent("A.mp4"), sidecar = root.appendingPathComponent("A.nfo")
    try Data("<movie><title>broken".utf8).write(to: sidecar)
    try Data("<movie><title>Updated B</title></movie>".utf8).write(to: root.appendingPathComponent("B.nfo"))
    let failed = try LibraryScanner.scanResult(root: root, previous: old.incremental)
    let merged = failed.catalogItems(preserving: old.items)
    #expect(failed.metadataReadFailureIDs == [a.path])
    #expect(merged.first { $0.id == a.path }?.title == "Original A")
    #expect(merged.first { $0.id == a.path }?.localMetadata?.metadataReadFailed == true)
    #expect(merged.contains { $0.title == "Updated B" })
    #expect(failed.incremental?.manifest.files[a.path] == nil)
    let index = LibraryIndexStore(file: parent.appendingPathComponent("index.json"))
    try await index.save(items: merged, root: root, incremental: failed.incremental?.manifest)
    let cold = try await LibraryIndexStore(file: parent.appendingPathComponent("index.json")).load(root: root)!
    let next = try LibraryScanner.scanResult(root: root, previous: cold.incrementalState)
    #expect(next.catalogItems(preserving: cold.items).first { $0.id == a.path }?.title == "Original A")
    #expect(next.nfoReadCount == 1 && next.reusedCount == 1)
    let matches = MetadataStore(file: parent.appendingPathComponent("matches.json"))
    let records = try matches.set(targetID: a.path, candidate: MetadataCandidate(provider: .tmdb, externalID: 1, kind: .movie, title: "Manual A"))
    #expect(MetadataStore.apply(records, to: merged).first { $0.id == a.path }?.title == "Manual A")
    try Data("<movie><title>Repaired A</title></movie>".utf8).write(to: sidecar)
    let repaired = try LibraryScanner.scanResult(root: root, previous: next.incremental)
    let repairedItems = repaired.catalogItems(preserving: cold.items)
    #expect(repaired.metadataReadFailureIDs.isEmpty && repairedItems.first { $0.id == a.path }?.title == "Repaired A")
    #expect(repairedItems.first { $0.id == a.path }?.localMetadata?.metadataReadFailed != true)
    try FileManager.default.removeItem(at: sidecar)
    let removed = try LibraryScanner.scanResult(root: root, previous: repaired.incremental)
    #expect(removed.metadataReadFailureIDs.isEmpty && removed.catalogItems(preserving: repairedItems).first { $0.id == a.path }?.title == "A")
    try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: parent.appendingPathComponent("missing.nfo"))
    let brokenLink = try LibraryScanner.scanResult(root: root, previous: repaired.incremental)
    #expect(brokenLink.metadataReadFailureIDs.contains(a.path))
    #expect(brokenLink.catalogItems(preserving: repairedItems).first { $0.id == a.path }?.title == "Repaired A")
  }
  @Test func sharedShowFailureKeepsHierarchyAndMarksSeriesAndSeason() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let season = root.appendingPathComponent("Season 1")
    try FileManager.default.createDirectory(at: season, withIntermediateDirectories: true)
    for number in 1...2 { try Data().write(to: season.appendingPathComponent("Show.S01E0\(number).mp4")) }
    try Data("<tvshow><title>Original Show</title></tvshow>".utf8).write(to: root.appendingPathComponent("tvshow.nfo"))
    let old = try LibraryScanner.scanResult(root: root)
    let oldCatalog = LibraryCatalog.build(old.items)
    try Data("<tvshow>broken".utf8).write(to: root.appendingPathComponent("tvshow.nfo"))
    let failed = try LibraryScanner.scanResult(root: root, previous: old.incremental)
    let catalog = LibraryCatalog.build(failed.catalogItems(preserving: old.items))
    #expect(failed.metadataReadFailureIDs.count == 2)
    #expect(catalog.root[0].id == oldCatalog.root[0].id && catalog.root[0].title == "Original Show")
    #expect(catalog.root[0].localMetadata?.metadataReadFailed == true)
    #expect(catalog.children[catalog.root[0].id]?.first?.localMetadata?.metadataReadFailed == true)
  }
  @Test func NASDescriptionRetentionDoesNotRestoreOldMountBindings() async throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: parent) }
    let oldMount = parent.appendingPathComponent("old"), newMount = parent.appendingPathComponent("new")
    for mount in [oldMount, newMount] {
      let folder = mount.appendingPathComponent("Show/Season 1")
      try movie(folder, name: "2026", title: "Original Episode")
      try Data("<episodedetails><title>Original Episode</title><showtitle>Original Show</showtitle><season>1</season><episode>2</episode></episodedetails>".utf8).write(to: folder.appendingPathComponent("2026.nfo"))
    }
    try Data([0]).write(to: oldMount.appendingPathComponent("Show/poster.jpg"))
    let profile = try SMBProfile(address: "fixture.invalid/Shows", username: "", guest: true, rememberPassword: false)
    let old = try LibraryScanner.scanResult(root: oldMount, allowedResolvedRoot: oldMount).withSMBIdentity(profile: profile, mount: oldMount)
    try Data("<bad>".utf8).write(to: newMount.appendingPathComponent("Show/Season 1/2026.nfo"))
    let failed = try LibraryScanner.scanResult(root: newMount, allowedResolvedRoot: newMount).withSMBIdentity(profile: profile, mount: newMount)
    let kept = failed.catalogItems(preserving: old.items)[0]
    #expect(failed.metadataReadFailureIDs == [kept.id] && kept.title == "Original Episode")
    #expect(kept.url?.contains("/new/") == true && kept.url?.contains("/old/") == false)
    #expect(kept.poster == nil && kept.localMetadata?.seriesPoster == nil)
    #expect(kept.localMetadata?.seriesRoot?.hasPrefix(newMount.path) == true)
    #expect(kept.localMetadata?.seriesRoot == newMount.appendingPathComponent("Show").path)
    #expect(LibraryCatalog.build([kept]).root[0].id == LibraryCatalog.build(old.items).root[0].id)
    let store = SMBLibraryIndexStore(root: parent.appendingPathComponent("cache"))
    try await store.save([kept], profile: profile, mount: newMount)
    let saved = try await store.load(profile: profile)!
    let rebound = try saved.binding(profile: profile, mount: parent.appendingPathComponent("another"))
    #expect(rebound[0].id == kept.id && rebound[0].localMetadata?.metadataReadFailed == true)
    #expect(LibraryCatalog.build(rebound).root[0].id == LibraryCatalog.build([kept]).root[0].id)
  }
}

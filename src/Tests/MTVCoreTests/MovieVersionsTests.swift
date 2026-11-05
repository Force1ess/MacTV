import Foundation
import Testing
@testable import MTVCore

struct MovieVersionsTests {
  func fixture(_ root: URL, name: String, xml: String) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent(name + ".mp4"))
    try Data(xml.utf8).write(to: root.appendingPathComponent(name + ".nfo"))
  }
  @Test func movieNFOIdentifiersAreExplicitAndConflictingValuesDoNotGroup() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let cases: [(String, String, Int?)] = [
      ("modern", "<uniqueid type=\"tmdb\">603</uniqueid>", 603),
      ("legacy", "<tmdbid>603</tmdbid>", 603),
      ("consistent", "<tmdbid>603</tmdbid><uniqueid type=\"tmdb\">603</uniqueid>", 603),
      ("conflict", "<tmdbid>603</tmdbid><uniqueid type=\"tmdb\">604</uniqueid>", nil),
      ("imdb", "<uniqueid type=\"imdb\">603</uniqueid>", nil),
      ("invalid", "<uniqueid type=\"tmdb\">0</uniqueid>", nil),
      ("signed", "<tmdbid>+603</tmdbid>", nil),
    ]
    for (name, fields, _) in cases { try fixture(root, name: name, xml: "<movie><title>同名影片</title>\(fields)</movie>") }
    try fixture(root, name: "Episode.S01E01", xml: "<episodedetails><title>同名影片</title><uniqueid type=\"tmdb\">603</uniqueid></episodedetails>")
    let items = try LibraryScanner.scan(root: root)
    for (name, _, expected) in cases { #expect(items.first { $0.id.hasSuffix("/" + name + ".mp4") }?.localMetadata?.movieTMDBID == expected) }
    #expect(items.first { $0.id.hasSuffix("/Episode.S01E01.mp4") }?.localMetadata?.movieTMDBID == nil)
  }
  @Test func legacyIncrementalCacheReparsesOnceAndNewIdentitySurvivesWarmCache() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try fixture(root, name: "Movie", xml: "<movie><title>Movie</title><uniqueid type=\"tmdb\">603</uniqueid></movie>")
    let first = try LibraryScanner.scanResult(root: root)
    var oldManifest = first.incremental!.manifest; oldManifest.metadataParserVersion = nil
    var oldItem = first.items[0]; oldItem.localMetadata?.movieTMDBID = nil
    let legacy = LibraryIncrementalState(root: root, items: [oldItem], manifest: oldManifest)
    let refreshed = try LibraryScanner.scanResult(root: root, previous: legacy)
    #expect(refreshed.reusedCount == 0 && refreshed.items[0].localMetadata?.movieTMDBID == 603)
    let warm = try LibraryScanner.scanResult(root: root, previous: refreshed.incremental)
    #expect(warm.reusedCount == 1 && warm.nfoReadCount == 0 && warm.items[0].localMetadata?.movieTMDBID == 603)
    let roundtrip = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(warm.items[0]))
    #expect(roundtrip.localMetadata?.movieTMDBID == 603)
  }
  @Test func manualMovieMatchSetsIdentityButAutomaticMatchCannotOverrideSidecar() {
    let candidate = MetadataCandidate(provider: .tmdb, externalID: 604, kind: .movie, title: "Matched")
    var item = MediaItem(id: "film", title: "Original", localMetadata: LocalMediaMetadata(hasSidecar: true, movieTMDBID: 603))
    var match = MetadataMatch(targetID: item.id, candidate: candidate, selectedAt: Date(), origin: .automatic)
    #expect(MetadataStore.apply([item.id: match], to: [item])[0].localMetadata?.movieTMDBID == 603)
    match.origin = .manual
    #expect(MetadataStore.apply([item.id: match], to: [item])[0].localMetadata?.movieTMDBID == 604)
    item.localMetadata = nil
    #expect(MetadataStore.apply([item.id: match], to: [item])[0].localMetadata?.movieTMDBID == 604)
  }
  @Test func versionsReadFullCachesIndependentOfSearchAndDisplayBudget() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let sources = SavedLibrarySourcesStore(file: root.appendingPathComponent("sources.json"))
    let local = LibraryIndexStore(file: root.appendingPathComponent("index.json"))
    for n in 0..<2 {
      let media = root.appendingPathComponent("unmounted-\(n)")
      let files = (0..<6000).map { index in
        MediaItem(id: media.appendingPathComponent("Movie-\(index).mp4").path, title: "Movie",
          url: media.appendingPathComponent("Movie-\(index).mp4").absoluteString,
          localMetadata: LocalMediaMetadata(movieTMDBID: index == 5999 ? 603 : nil))
      }
      try await local.save(items: files, root: media)
      try await sources.remember(LibrarySourceSelection(path: media.path), title: "Disk \(n)")
    }
    let store = LibraryOverviewStore(sources: sources, local: local, nas: SMBLibraryIndexStore(root: root.appendingPathComponent("nas")), profiles: SMBProfileStore(file: root.appendingPathComponent("profiles.json")))
    #expect(try await store.load().map { $0.cards.count } == [6000, 4000])
    #expect(try await store.load(query: "Disk 0").count == 1)
    let versions = try await store.versions(movieTMDBID: 603)
    #expect(versions.versions.count == 2 && !versions.limited && versions.unavailableSources.isEmpty)
    #expect(versions.versions.allSatisfy { $0.card.id.hasSuffix("5999.mp4") })
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("unmounted-0").path))
    #expect(try await store.versions(movieTMDBID: 604).versions.isEmpty)
  }
  @Test func versionsAreBoundedRetainPreferredAndReportUnavailableSources() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let sources = SavedLibrarySourcesStore(file: root.appendingPathComponent("sources.json"))
    let local = LibraryIndexStore(file: root.appendingPathComponent("index.json"))
    let media = root.appendingPathComponent("unmounted")
    let files = (0..<205).map { MediaItem(id: media.appendingPathComponent("file-\($0).mp4").path, title: "Movie",
      url: media.appendingPathComponent("file-\($0).mp4").absoluteString, localMetadata: LocalMediaMetadata(movieTMDBID: 603)) }
    try await local.save(items: files, root: media)
    let source = try await sources.remember(LibrarySourceSelection(path: media.path), title: "Disk")[0]
    try await sources.remember(LibrarySourceSelection(smbProfileID: UUID()), title: "Removed NAS")
    let store = LibraryOverviewStore(sources: sources, local: local, nas: SMBLibraryIndexStore(root: root.appendingPathComponent("nas")), profiles: SMBProfileStore(file: root.appendingPathComponent("profiles.json")))
    let preferred = LibraryMovieVersion.ID(sourceID: source.id, itemID: files[204].id)
    let result = try await store.versions(movieTMDBID: 603, preferred: preferred)
    #expect(result.versions.count == 200 && result.limited && result.versions.contains { $0.id == preferred })
    #expect(result.unavailableSources == ["Removed NAS"])
  }
}

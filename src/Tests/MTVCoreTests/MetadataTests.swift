import Foundation
import Testing

@testable import MTVCore

struct MetadataTests {
  @Test func localizedSeriesSurvivesReopeningTheMetadataStore() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("matches.json")
    let candidate = MetadataCandidate(provider: .tmdb, externalID: 321, kind: .series, title: "测试剧集")
    try MetadataStore(file: file).saveLocalizedSeries([123: candidate])
    #expect(try MetadataStore(file: file).loadLocalizedSeries()[123] == candidate)
    #expect(try MetadataStore(file: file).load().isEmpty)
  }
  @Test func providerParsingKeepsAttributionAndRejectsUnauthorizedImages() throws {
    let data = Data(
      #"[{"show":{"id":84,"name":"Family Guy","premiered":"1999-01-31","summary":"<p>A &amp; B</p>","image":{"medium":"https://static.tvmaze.com/uploads/images/test.jpg"}}}]"#
        .utf8)
    let values = try MetadataClient.decode(data, kind: .series, provider: .tvmaze)
    #expect(values.first?.year == 1999)
    #expect(values.first?.overview == "A & B")
    #expect(values.first?.attribution.absoluteString == "https://www.tvmaze.com/shows/84")
    let bad = MetadataCandidate(
      provider: .tvmaze, externalID: 84, kind: .series, title: "Test",
      poster: "file:///private/fixture/photo.jpg")
    #expect(throws: (any Error).self) { try bad.validate() }
    #expect(throws: (any Error).self) {
      try MetadataClient.decode(data, kind: .movie, provider: .tvmaze)
    }
    let movie = try MetadataClient.decode(
      Data(
        #"{"results":[{"id":11,"title":"电影","release_date":"1977-01-01","overview":"简介","poster_path":"/test.jpg"}]}"#
          .utf8), kind: .movie, provider: .tmdb)
    #expect(movie.first?.poster == "https://image.tmdb.org/t/p/w500/test.jpg")
    #expect(movie.first?.attribution.absoluteString == "https://www.themoviedb.org/movie/11")
  }
  @Test func matchesPersistWithoutChangingMediaIdentityAndCanBeReversed() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mtv-metadata-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MetadataStore(file: root.appendingPathComponent("cache/matches.json"))
    let episode = MediaItem(
      id: "/library/Show/S01E01.mp4", title: "First", url: "file:///library/Show/S01E01.mp4",
      localMetadata: LocalMediaMetadata(
        seriesTitle: "Original Show", seriesRoot: "/library/Show", season: 1, episode: 1))
    let original = LibraryCatalog.build([episode]).root[0]
    let candidate = MetadataCandidate(
      provider: .tvmaze, externalID: 84, kind: .series, title: "Corrected Show", year: 1999,
      overview: "Provider description")
    _ = try store.set(targetID: original.id, candidate: candidate)
    let fresh = MetadataStore(file: store.file)
    let corrected = MetadataStore.apply(try fresh.load(), to: [episode])
    let catalog = LibraryCatalog.build(corrected)
    #expect(catalog.root[0].title == "Corrected Show")
    #expect(catalog.root[0].id == original.id)
    #expect(
      corrected[0].id == episode.id && corrected[0].url == episode.url
        && corrected[0].title == "First")
    #expect(catalog.root[0].metadataAttribution == candidate.attribution.absoluteString)
    _ = try fresh.set(targetID: original.id, candidate: nil)
    #expect(
      LibraryCatalog.build(MetadataStore.apply(try fresh.load(), to: [episode])).root[0].title
        == "Original Show")
  }
  @Test func corruptCacheIsReportedAndNeverOverwrittenAsEmpty() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mtv-metadata-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("matches.json")
    let original = Data("broken metadata cache".utf8)
    try original.write(to: file)
    let store = MetadataStore(file: file)
    #expect(throws: (any Error).self) { try store.set(targetID: "movie", candidate: nil) }
    #expect(try Data(contentsOf: file) == original)
  }
  @Test func maintenanceBackupPreservesMatchesAndUsesPrivateFilePermissions() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mtv-metadata-backup-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MetadataStore(file: root.appendingPathComponent("matches.json"))
    let candidate = MetadataCandidate(provider: .tvmaze, externalID: 1, kind: .series, title: "Owned fixture")
    _ = try store.set(targetID: "owned", candidate: candidate)
    let before = try Data(contentsOf: store.file)
    let candidateBackup = try store.backupForMaintenance()
    let backup = try #require(candidateBackup)
    #expect(try Data(contentsOf: backup) == before)
    #expect(try Data(contentsOf: store.file) == before)
    #expect(try FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? Int == 0o600)
    #expect(try store.load()["owned"]?.candidate == candidate)
  }

}

import Foundation
import Testing

@testable import MTVCore

struct AutomaticMetadataTests {
  private func movie(_ title: String, year: Int? = 2020, sidecar: Bool? = false) -> MediaItem {
    MediaItem(
      id: "/movies/" + title, title: title,
      localMetadata: LocalMediaMetadata(year: year, hasSidecar: sidecar))
  }
  @Test func knownSeriesYearDisambiguatesRemakesWithoutGuessingConflictingYears() throws {
    let episode = MediaItem(id: "owned-episode", title: "Pilot", localMetadata: LocalMediaMetadata(
      year: 1994, seriesTitle: "Example Show", seriesRoot: "/shows/example", season: 1, episode: 1, hasSidecar: false))
    let target = try #require(AutomaticMetadata.targets(files: [episode], matches: [:]).first)
    let original = MetadataCandidate(provider: .tvmaze, externalID: 1, kind: .series, title: "Example Show", year: 1994)
    let remake = MetadataCandidate(provider: .tvmaze, externalID: 2, kind: .series, title: "Example Show", year: 2010)
    #expect(target.year == 1994)
    #expect(AutomaticMetadata.uniqueMatch(target: target, candidates: [original, remake])?.externalID == 1)
    var next = episode; next.id = "owned-next"; next.localMetadata?.episode = 2; next.localMetadata?.year = 2010
    #expect(AutomaticMetadata.targets(files: [episode, next], matches: [:]).isEmpty)
    var unknown = episode; unknown.localMetadata?.year = nil
    let unknownTarget = try #require(AutomaticMetadata.targets(files: [unknown], matches: [:]).first)
    #expect(AutomaticMetadata.uniqueMatch(target: unknownTarget, candidates: [original, remake]) == nil)
  }

  @Test func plannerProtectsSidecarsUnknownProvenanceAndManualMatches() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mtv-auto-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MetadataStore(file: root.appendingPathComponent("matches.json"))
    let manual = movie("Manual")
    try store.set(
      targetID: manual.id,
      candidate: MetadataCandidate(
        provider: .tmdb, externalID: 1, kind: .movie, title: "Manual", year: 2020))
    let files = [movie("New"), movie("NFO", sidecar: true), movie("Unknown", sidecar: nil), manual]
    #expect(
      AutomaticMetadata.targets(files: files, matches: try store.load()).map(\.item.title) == [
        "New"
      ])
    let episode = MediaItem(
      id: "episode", title: "First",
      localMetadata: LocalMediaMetadata(
        seriesTitle: "Show", seriesRoot: "/shows/Show", season: 1, episode: 1, hasSidecar: true))
    #expect(AutomaticMetadata.targets(files: [episode], matches: [:]).isEmpty)
  }
  @Test func matchingRequiresUniqueTitleAndMovieYearAndSupportsOriginalTitles() throws {
    let target = AutomaticMetadata.targets(
      files: [movie("Blade Runner 2049", year: 2017)], matches: [:])[0]
    var correct = MetadataCandidate(
      provider: .tmdb, externalID: 1, kind: .movie, title: "银翼杀手2049", year: 2017)
    correct.originalTitle = "Blade Runner 2049"
    let wrong = MetadataCandidate(
      provider: .tmdb, externalID: 2, kind: .movie, title: "Blade Runner 2049", year: 2020)
    #expect(
      AutomaticMetadata.uniqueMatch(target: target, candidates: [wrong, correct])?.externalID == 1)
    let duplicate = MetadataCandidate(
      provider: .tmdb, externalID: 3, kind: .movie, title: "Blade.Runner.2049", year: 2017)
    #expect(AutomaticMetadata.uniqueMatch(target: target, candidates: [correct, duplicate]) == nil)
    let unknownYear = AutomaticMetadata.targets(
      files: [movie("Blade Runner 2049", year: nil)], matches: [:])[0]
    #expect(AutomaticMetadata.uniqueMatch(target: unknownYear, candidates: [correct]) == nil)
    #expect(AutomaticMetadata.uniqueMatch(target: target, candidates: [wrong]) == nil)
  }
  @Test func yearlessMovieNeedsUniqueDatedArtworkAndNonNumericTitle() throws {
    let target = try #require(AutomaticMetadata.targets(files: [movie("Arrival", year: nil)], matches: [:]).first)
    let candidate = MetadataCandidate(provider: .tmdb, externalID: 1, kind: .movie, title: "Arrival", year: 2016,
      poster: "https://image.tmdb.org/t/p/w500/poster.jpg")
    let remake = MetadataCandidate(provider: .tmdb, externalID: 2, kind: .movie, title: "Arrival", year: 1996)
    #expect(AutomaticMetadata.uniqueMatch(target: target, candidates: [candidate]) == candidate)
    #expect(AutomaticMetadata.uniqueMatch(target: target, candidates: [candidate, remake]) == nil)
    let numeric = try #require(AutomaticMetadata.targets(files: [movie("2026", year: nil)], matches: [:]).first)
    let numberTitle = MetadataCandidate(provider: .tmdb, externalID: 3, kind: .movie, title: "2026", year: 2026,
      poster: "https://image.tmdb.org/t/p/w500/poster.jpg")
    #expect(AutomaticMetadata.uniqueMatch(target: numeric, candidates: [numberTitle]) == nil)
  }

  @Test func bilingualSeriesUsesLocalizedProviderAndRetainsTokenFreeSearch() async throws {
    struct Client: MetadataSearching {
      func search(query: String, kind: MetadataKind, provider: MetadataProvider, token: String?) async throws -> [MetadataCandidate] {
        switch (provider, query) {
        case (.tmdb, "恶搞之家"):
          #expect(token == "fixture")
          return [.init(provider: provider, externalID: 1, kind: kind, title: query,
            poster: "https://image.tmdb.org/t/p/w500/poster.jpg")]
        case (.tvmaze, "Family Guy"):
          #expect(token == nil)
          return [.init(provider: provider, externalID: 2, kind: kind, title: query,
            poster: "https://static.tvmaze.com/poster.jpg")]
        default: return []
        }
      }
    }
    let episode = MediaItem(id: "episode", title: "First", localMetadata: LocalMediaMetadata(
      seriesTitle: "恶搞之家 Family Guy", seriesRoot: "/show", season: 1, episode: 1, hasSidecar: false))
    let target = try #require(AutomaticMetadata.targets(files: [episode], matches: [:]).first)
    #expect(try await AutomaticMetadata.resolve(target: target, client: Client(), token: "fixture")?.title == "恶搞之家")
    #expect(try await AutomaticMetadata.resolve(target: target, client: Client(), token: nil)?.title == "Family Guy")
  }

  @Test func automaticWriteDoesNotReplaceExistingAndLaterNFOWins() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mtv-auto-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MetadataStore(file: root.appendingPathComponent("matches.json"))
    var original = movie("Original")
    let automatic = MetadataCandidate(
      provider: .tmdb, externalID: 1, kind: .movie, title: "Provider Title", year: 2020)
    #expect(try store.insertAutomatic(targetID: original.id, candidate: automatic))
    #expect(try store.load()[original.id]?.origin == .automatic)
    #expect(try !store.insertAutomatic(targetID: original.id, candidate: automatic))
    original.localMetadata?.hasSidecar = true
    #expect(MetadataStore.apply(try store.load(), to: [original])[0].title == "Original")
    _ = try store.set(targetID: original.id, candidate: automatic)
    #expect(MetadataStore.apply(try store.load(), to: [original])[0].title == "Provider Title")
  }
  @Test func malformedSidecarStillPreventsAutomaticOverwrite() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mtv-auto-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("Movie.2020.mp4"))
    try Data("not XML".utf8).write(to: root.appendingPathComponent("Movie.2020.nfo"))
    let files = try LibraryScanner.scan(root: root)
    #expect(files.first?.localMetadata?.hasSidecar == true)
    #expect(AutomaticMetadata.targets(files: files, matches: [:]).isEmpty)
  }
}

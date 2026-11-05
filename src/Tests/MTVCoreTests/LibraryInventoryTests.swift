import Foundation
import Testing
@testable import MTVCore

struct LibraryInventoryTests {
  @Test func rootMovieVersionsKeepArtworkFromEitherFile() throws {
    let root = URL(fileURLWithPath: "/owned")
    let original = root.appendingPathComponent("Movie.mkv")
    let duplicate = root.appendingPathComponent("Movie-abcdef123456.mkv")
    let files = [
      MediaItem(id: original.path, title: "Movie", url: original.absoluteString),
      MediaItem(id: duplicate.path, title: "Movie", poster: "file:///owned/poster.jpg", url: duplicate.absoluteString),
    ]
    let report = LibraryInventoryReport(root: root, basis: "fixture", files: files)
    let card = try #require(report.rootCards.first)
    #expect(report.rootCards.count == 1)
    #expect(card.kind == .versions)
    #expect(card.poster == "file:///owned/poster.jpg")
    #expect(report.collections[card.id]?.count == 2)
  }

  @Test func seasonFoldersBracketEpisodesAndZeroNumberSpecialsStayInTheirSeries() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mtv-release-names-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let names = [
      "Example S02 第二季 (2026)/S02E01.2026.2160p.mkv",
      "Animation/Example Animation [01].mkv",
      "Animation/Example Animation [02].mkv",
      "[Team][示例动画 第四季][全集]/[Team][Example Show][4th - 01][总第67][1080p].mkv",
      "Sitcom/Season 24/Sitcom.S24E00.Holiday.1080p.mkv",
    ]
    for name in names + (1...6).map({ String(format: "别名/另一部动画 %02d.mkv", $0) }) {
      let file = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data().write(to: file)
    }
    let files = try LibraryScanner.scan(root: root)
    let catalog = LibraryCatalog.build(files)
    #expect(Set(catalog.root.map(\.title)) == ["Example", "Example Animation", "Sitcom", "示例动画", "另一部动画"])
    #expect(catalog.root.allSatisfy { $0.kind == .series })
    #expect(files.contains { $0.title == "第1集" && $0.localMetadata?.season == 2 })
    #expect(files.contains { $0.title == "Holiday" && $0.localMetadata?.episode == 0 })
  }

  @Test func realReleaseShapesKeepEpisodesAndExtrasOutOfMovieWall() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mtv-organize-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let names = [
      "Show/[LoliHouse] Danganronpa 3 - Mirai Hen - 01 [BDRip 1080p HEVC-10bit FLAC].mkv",
      "Show/[LoliHouse] Danganronpa 3 - Mirai Hen - 01 [BDRip 1080p HEVC-10bit FLAC]-79c6d977bf5f.mkv",
      "Show/[LoliHouse] Danganronpa 3 - Mirai Hen - 02 [BDRip 1080p HEVC-10bit FLAC].mkv",
      "Show/SPs/[LoliHouse] Danganronpa 3 - Menu [BDRip 1080p HEVC].mkv",
      "Show/SPs/[LoliHouse] Danganronpa 3 - Menu [BDRip 1080p HEVC]-1ef3805b7a34.mkv",
      "[KTXP][130045][13(OAD)][GB_CN][X264_AAC][720p].mp4",
      "Menu (2022).mkv"
    ]
    for name in names {
      let file = root.appendingPathComponent(name)
      try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data().write(to: file)
    }
    let files = try LibraryScanner.scan(root: root)
    let report = LibraryInventoryReport(root: root, basis: "owned-fixture", files: files)
    #expect(report.summary.files == names.count)
    #expect(report.summary.series == 1)
    #expect(report.summary.extraFiles == 3)
    #expect(report.summary.versionCollections == 1)
    #expect(report.summary.movies == 1)
    #expect(report.summary.unparsedEpisodes == 0)
    #expect(report.summary.unreachableFiles == 0)
    #expect(report.summary.malformedTitles == 0)
    #expect(report.checkPassed)
    #expect(report.rootCards.contains { $0.title == "Menu" && !$0.isLibraryCollection })
    #expect(!report.rootCards.contains { $0.title.contains("LoliHouse") || $0.title.contains("KTXP") })
    let encoded = try JSONEncoder().encode(report)
    let roundTrip = try JSONDecoder().decode(LibraryInventoryReport.self, from: encoded)
    #expect(roundTrip.files.map(\.id) == files.sorted { $0.id < $1.id }.map(\.id))
  }
  @Test func auditFailsStaleUnparsedOrInaccessibleCatalogRatherThanHidingWarnings() {
    let root = URL(fileURLWithPath: "/owned")
    let path = root.appendingPathComponent("[Group] Show - 01 [1080p].mkv")
    let item = MediaItem(id: path.path, title: "Group] Show", url: path.absoluteString)
    let report = LibraryInventoryReport(root: root, basis: "cached-index", files: [item])
    #expect(!report.checkPassed)
    #expect(report.issues.contains { $0.code == "release-label-in-title" && $0.severity == "error" })
    #expect(report.issues.contains { $0.code == "episode-not-classified" && $0.itemIDs == [item.id] })
    #expect(report.summary.missingPosters == 1)
  }
}

struct LibraryAliasAndSiblingTests {
  @Test func officialAliasCanMatchButAmbiguousAliasesRemainUnresolved() throws {
    let episode = MediaItem(id: "/show/1", title: "One", localMetadata: LocalMediaMetadata(seriesTitle: "Short Name", seriesRoot: "/show", season: 1, episode: 1, hasSidecar: false))
    let target = try #require(AutomaticMetadata.targets(files: [episode], matches: [:]).first)
    var first = MetadataCandidate(provider: .tvmaze, externalID: 1, kind: .series, title: "Long official name")
    first.officialAliases = try MetadataClient.decodeTVAliases(Data(#"[{"name":"Short Name"},{"name":"Other Name"}]"#.utf8))
    #expect(AutomaticMetadata.uniqueMatch(target: target, candidates: [first])?.externalID == 1)
    var other = MetadataCandidate(provider: .tvmaze, externalID: 2, kind: .series, title: "Another show")
    other.officialAliases = ["Short Name"]
    #expect(AutomaticMetadata.uniqueMatch(target: target, candidates: [first, other]) == nil)
    #expect(!MediaRecognition.isExtra(URL(fileURLWithPath: "/movies/Menu (2022).mkv")))
    #expect(MediaRecognition.isExtra(URL(fileURLWithPath: "/show/[Group][Show][NCED1][1080P].mkv")))
    let dubbed = MediaRecognition.filename(URL(fileURLWithPath: "[Cleo]WataMote_-_01_(Dual Audio_10bit_BD1080p_x265).mkv"))
    #expect(dubbed.seriesTitle == "WataMote" && dubbed.episode == 1)
    #expect(MediaRecognition.filename(URL(fileURLWithPath: "[DBD-Raws][Film][1080P][HEVC].mkv")).title == "Film")
  }
}

struct LibraryNumberedSiblingTests {
  @Test func numberOnlyEpisodesNeedTrustedSiblingAndKeepPhysicalIdentity() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mtv-sibling-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for name in ["Known Show 01.mp4", "Known Show 02.mp4", "Other Film 02.mp4"] { try Data().write(to: root.appendingPathComponent(name)) }
    let scan = try LibraryScanner.scanResult(root: root)
    var known = try #require(scan.items.first { $0.url?.contains("01.mp4") == true })
    known.localMetadata = LocalMediaMetadata(seriesTitle: "Trusted Show", seriesRoot: root.path, season: 2, episode: 1, seriesPoster: "file:///owned/poster.jpg", hasSidecar: true)
    let result = LibraryLinkedMetadata.apply(scan, companions: [known], root: root)
    let second = try #require(result.items.first { $0.id.hasSuffix("Known Show 02.mp4") })
    #expect(second.localMetadata?.seriesTitle == "Trusted Show")
    #expect(second.localMetadata?.season == 2 && second.localMetadata?.episode == 2)
    #expect(second.poster == "file:///owned/poster.jpg")
    #expect(second.id == root.appendingPathComponent("Known Show 02.mp4").path)
    #expect(result.items.first { $0.id.hasSuffix("Other Film 02.mp4") }?.localMetadata?.episode == nil)
  }
}

struct LibraryRenderedTitleTests {
  @Test func inspectionIncludesCollectionTitlesNotOnlyLeafFilenames() {
    let item = MediaItem(id: "/owned/1.mkv", title: "第1集", url: "file:///owned/1.mkv", localMetadata: LocalMediaMetadata(seriesTitle: "Group][Show", seriesRoot: "/owned", season: 1, episode: 1))
    let report = LibraryInventoryReport(root: URL(fileURLWithPath: "/owned"), basis: "owned", files: [item])
    #expect(!report.checkPassed)
    #expect(report.issues.first { $0.code == "release-label-in-title" }?.itemIDs.contains { $0.hasPrefix("mtv:series:") } == true)
    let hint = MediaRecognition.filename(URL(fileURLWithPath: "[DBD-Raws][Show][Part][01][1080P].mkv"))
    #expect(hint.seriesTitle == "Show Part")
  }
}

struct LibraryDisplayedPathTests {
  @Test func restoreUsesFlattenedEpisodePathAndKeepsStructuralSeasonCompatibility() throws {
    func episode(_ id: String, _ show: String) -> MediaItem {
      MediaItem(id: id, title: "First", url: "file://" + id, localMetadata: LocalMediaMetadata(seriesTitle: show, seriesRoot: "/" + show, season: 1, episode: 1))
    }
    let files = [episode("/Show/a.mp4", "Show"), episode("/Show/b.mp4", "Show"), episode("/Other/c.mp4", "Other")]
    let catalog = LibraryCatalog.build(files)
    let show = try #require(catalog.root.first { $0.title == "Show" })
    let versions = try #require(catalog.displayedChildren(of: show).first)
    #expect(versions.kind == .versions)
    #expect(catalog.restoringDisplayedPath([show.id, versions.id]).map(\.id) == [show.id, versions.id])
    let season = try #require(catalog.children[show.id]?.first)
    #expect(catalog.restoringDisplayedPath([show.id, season.id]).map(\.id) == [show.id, season.id])
    let other = try #require(catalog.root.first { $0.title == "Other" })
    let wrongSeason = try #require(catalog.children[other.id]?.first)
    #expect(catalog.restoringDisplayedPath([show.id, wrongSeason.id]).map(\.id) == [show.id])
  }
  @Test func officialAbbreviationBeforeSubtitleIsConservativeAndUnique() throws {
    func target(_ title: String) throws -> AutomaticMetadataTarget {
      let file = MediaItem(id: title, title: title, url: "file:///fixture/episode.mkv",
        localMetadata: LocalMediaMetadata(seriesTitle: title, seriesRoot: "/fixture", season: 1, episode: 1, hasSidecar: false))
      return try #require(AutomaticMetadata.targets(files: [file], matches: [:]).first)
    }
    var first = MetadataCandidate(provider: .tvmaze, externalID: 1, kind: .series, title: "Watashi ga Motenai no wa Dou Kangaete mo Omaera ga Warui!")
    first.officialAliases = ["WataMote: No Matter How I Look at It, It's You Guys' Fault I'm Not Popular!"]
    #expect(AutomaticMetadata.uniqueMatch(target: try target("Watamote"), candidates: [first])?.externalID == 1)
    var other = MetadataCandidate(provider: .tvmaze, externalID: 2, kind: .series, title: "Different show")
    other.officialAliases = ["WataMote: Another adaptation"]
    #expect(AutomaticMetadata.uniqueMatch(target: try target("Watamote"), candidates: [first, other]) == nil)
    first.officialAliases = ["Star Trek: Discovery"]
    #expect(AutomaticMetadata.uniqueMatch(target: try target("Star Trek"), candidates: [first]) == nil)
    first.officialAliases = ["AnimeX: Special"]
    first = MetadataCandidate(provider: .tvmaze, externalID: 1, kind: .series, title: "AnimeX Second Season")
    first.officialAliases = ["AnimeX: Special"]
    #expect(AutomaticMetadata.uniqueMatch(target: try target("AnimeX"), candidates: [first]) == nil)
    first = MetadataCandidate(provider: .tvmaze, externalID: 1, kind: .series, title: "Different language name"); first.officialAliases = ["IT: New Story"]
    #expect(AutomaticMetadata.uniqueMatch(target: try target("IT"), candidates: [first]) == nil)
    first = MetadataCandidate(provider: .tvmaze, externalID: 1, kind: .series, title: "Watamote Season Two")
    #expect(AutomaticMetadata.uniqueMatch(target: try target("Watamote"), candidates: [first]) == nil)
  }

  @Test func explosionGalleryNeedsDirectoryAndReleaseQualifierTogether() {
    #expect(MediaRecognition.isExtra(URL(fileURLWithPath: "/release/爆炸/[Group][Example Show][Explosion][01][1080P].mkv")))
    #expect(MediaRecognition.isExtra(URL(fileURLWithPath: "/release/Explosion/[Group][Other Show][Explosion][48][BDRip].mkv")))
    #expect(!MediaRecognition.isExtra(URL(fileURLWithPath: "/movies/Explosion (2020).mkv")))
    #expect(!MediaRecognition.isExtra(URL(fileURLWithPath: "/release/Explosion/[Group][Explosion][01][1080P].mkv")))
    #expect(!MediaRecognition.isExtra(URL(fileURLWithPath: "/release/Season 1/[Group][Example Show][Explosion][01][1080P].mkv")))
    #expect(!MediaRecognition.isExtra(URL(fileURLWithPath: "/release/Explosion/Example Show S01E01.mkv")))
  }

}

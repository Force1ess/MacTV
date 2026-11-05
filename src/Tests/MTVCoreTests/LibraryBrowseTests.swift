import Foundation
import Testing
@testable import MTVCore

struct LibraryBrowseTests {
  @Test func recentSeriesUsesLatestAddedEpisodeWithoutReorderingEpisodes() throws {
    let old = Date(timeIntervalSince1970: 100)
    let recent = Date(timeIntervalSince1970: 300)
    let episode1 = MediaItem(id: "e1", title: "First", localMetadata:
      LocalMediaMetadata(seriesTitle: "Series", seriesRoot: "/owned/series", season: 1, episode: 1), addedAt: recent)
    let episode2 = MediaItem(id: "e2", title: "Second", localMetadata:
      LocalMediaMetadata(seriesTitle: "Series", seriesRoot: "/owned/series", season: 1, episode: 2), addedAt: old)
    let movie = MediaItem(id: "movie", title: "A Movie", addedAt: Date(timeIntervalSince1970: 200))
    let undated = MediaItem(id: "unknown", title: "Aardvark")
    let catalog = LibraryCatalog.build([episode1, episode2, movie, undated])
    let series = try #require(catalog.root.first { $0.kind == .series })
    let season = try #require(catalog.children[series.id]?.first)
    #expect(series.addedAt == recent && season.addedAt == recent)
    #expect(LibraryBrowseOptions(order: .newestAdded).apply(catalog.root).map(\.id) == [series.id, movie.id, undated.id])
    #expect(catalog.displayedChildren(of: series).map(\.id) == [episode1.id, episode2.id])
  }
  @Test func kindsSeparateMoviesCollectionsAndEpisodeSearchHits() {
    let movie = MediaItem(id: "movie", title: "Movie", url: "file:///owned/movie.mp4")
    let series = MediaItem(id: "series", title: "Show", kind: .series)
    let episode = MediaItem(id: "episode", title: "Pilot", localMetadata: LocalMediaMetadata(season: 1, episode: 1))
    let files = [movie, series, episode]
    #expect(LibraryBrowseOptions(kind: .movies).apply(files).map(\.id) == [movie.id])
    #expect(Set(LibraryBrowseOptions(kind: .series).apply(files).map(\.id)) == [series.id, episode.id])
    #expect(movie.url == "file:///owned/movie.mp4" && files.count == 3)
  }
  @Test func titleAndYearSortAreNaturalStableAndKeepUnknownYearsLast() {
    let two = MediaItem(id: "two", title: "Film 2", localMetadata: LocalMediaMetadata(year: 1999))
    let ten = MediaItem(id: "ten", title: "Film 10", localMetadata: LocalMediaMetadata(year: 2024))
    let unknown = MediaItem(id: "unknown", title: "A", localMetadata: nil)
    #expect(LibraryBrowseOptions().apply([ten, two]).map(\.id) == [two.id, ten.id])
    #expect(LibraryBrowseOptions(order: .reverseTitle).apply([two, ten]).map(\.id) == [ten.id, two.id])
    #expect(LibraryBrowseOptions(order: .newestYear).apply([unknown, two, ten]).map(\.id) == [ten.id, two.id, unknown.id])
    let a = MediaItem(id: "a", title: "Same"), b = MediaItem(id: "b", title: "Same")
    #expect(LibraryBrowseOptions(order: .reverseTitle).apply([b, a]).map(\.id) == [a.id, b.id])
  }
  @Test func rootSearchReusesUnicodeYearAndEpisodePolicy() {
    let movie = MediaItem(id: "movie", title: "Café 远行", localMetadata: LocalMediaMetadata(year: 2024))
    let episode = MediaItem(id: "episode", title: "开始", localMetadata: LocalMediaMetadata(seriesTitle: "远行", season: 2, episode: 3))
    #expect(LibraryBrowseOptions(kind: .movies).apply([movie, episode], query: "CAFE ２０２４").map(\.id) == [movie.id])
    #expect(LibraryBrowseOptions(kind: .series).apply([movie, episode], query: "远行 s02e03").map(\.id) == [episode.id])
    #expect(LibraryBrowseOptions(kind: .movies).apply([movie, episode], query: "s02e03").isEmpty)
  }
}

import Foundation
import Testing
@testable import MTVCore

struct ReleasePackExtrasTests {
  private func files(folder: String = "/fixture/[Group][Example Series][01-02TV全集+SP+特典映像]", group: String = "Group", title: String = "Example Series Bonus Stories", complete: Bool = true, sidecar: Bool = false) -> [MediaItem] {
    let episodes = (complete ? [1, 2] : [1]).map { number -> MediaItem in
      let file = URL(fileURLWithPath: folder).appendingPathComponent("[Group][Example Series][0\(number)][1080P].mkv")
      return MediaItem(id: file.path, title: "Episode", url: file.absoluteString,
        localMetadata: LocalMediaMetadata(seriesTitle: "Known", seriesRoot: folder, season: 1, episode: number, hasSidecar: true))
    }
    let extra = URL(fileURLWithPath: folder).appendingPathComponent("[\(group)][\(title)][1080P][BDRip].mkv")
    return episodes + [MediaItem(id: extra.path, title: title, url: extra.absoluteString, localMetadata: LocalMediaMetadata(hasSidecar: sidecar))]
  }
  @Test func labelledCompleteTVPackRecognizesSupplementWithoutChangingIdentity() throws {
    let original = files(), result = ReleasePackExtras.apply(original)
    #expect(result.last?.localMetadata?.isExtra == true)
    #expect(result.last?.id == original.last?.id && result.last?.url == original.last?.url)
    #expect(result.dropLast() == original.dropLast())
    #expect(ReleasePackExtras.apply(result) == result)
    #expect(LibraryCatalog.build(result).root.contains { $0.kind == .extras })
  }
  @Test func noGuessFromIncompleteDifferentOrUnlabelledRelease() {
    for sample in [files(folder: "/fixture/ordinary"), files(group: "OtherGroup"),
      files(title: "Example SeriesTwo Bonus Stories"), files(title: "Unrelated Film"),
      files(complete: false), files(sidecar: true), files(title: "Example Series")] {
      #expect(ReleasePackExtras.apply(sample) == sample)
    }
    var explicitMovie = files()
    explicitMovie[explicitMovie.count - 1].localMetadata?.year = 2020
    #expect(ReleasePackExtras.apply(explicitMovie) == explicitMovie)
    var damaged = files()
    damaged[0].localMetadata?.metadataReadFailed = true
    #expect(ReleasePackExtras.apply(damaged) == damaged)
  }
  @Test func manualMovieMatchingOverridesInferredSupplement() throws {
    let inferred = ReleasePackExtras.apply(files()), item = try #require(inferred.last)
    let candidate = MetadataCandidate(provider: .tmdb, externalID: 5, kind: .movie, title: "Confirmed Film", year: 2020)
    let match = MetadataMatch(targetID: item.id, candidate: candidate, selectedAt: Date(), origin: .manual)
    let applied = MetadataStore.apply([item.id: match], to: inferred)
    #expect(applied.last?.localMetadata?.isExtra == false)
    #expect(applied.last?.title == "Confirmed Film")
  }
}

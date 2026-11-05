import Foundation
import Testing
@testable import MTVCore

struct EpisodeContinuationTests {
  func item(_ id: String, season: Int = 1, episode: Int, end: Int? = nil, root: String = "/owned/Series", offline: Bool = false) -> MediaItem {
    MediaItem(id: id, title: "第\(episode)集", url: offline ? nil : URL(fileURLWithPath: root + "/" + id + ".mp4").absoluteString,
      localMetadata: LocalMediaMetadata(seriesTitle: "同名剧集", seriesRoot: root, season: season, episode: episode, episodeEnd: end, sourceReachable: !offline))
  }
  @Test func contiguousEpisodeRangeUsesEpisodeEndAndPreservesVersions() {
    let current = item("one-two", episode: 1, end: 2), duplicate = item("duplicate-two", episode: 2)
    let next = item("three-a", episode: 3), version = item("three-b", episode: 3)
    let plan = EpisodeContinuation.plan(current: current, files: [version, item("other-show", episode: 3, root: "/other/Series"), duplicate, next, current])
    #expect(plan?.candidates.map(\.id) == [next.id, version.id])
    #expect(plan?.label == "下一集" && plan?.message.contains("多个文件") == true)
  }
  @Test func gapsAndSeasonTransitionsAreExplicitNotSilentSkipping() {
    let current = item("one", episode: 1), later = item("four", episode: 4)
    let gap = EpisodeContinuation.plan(current: current, files: [current, later])
    #expect(gap?.label == "下一可用集" && gap?.message.contains("第2至3集") == true)
    let season = EpisodeContinuation.plan(current: current, files: [current, item("next-season", season: 2, episode: 1)])
    #expect(season?.label == "下一季" && season?.message.contains("是否完整") == true)
    #expect(EpisodeContinuation.plan(current: current, files: [current]) == nil)
  }
  @Test func offlineDescriptorsRemainChoicesWithoutInventingURLs() {
    let current = item("one", episode: 1), offline = item("two", episode: 2, offline: true)
    let plan = EpisodeContinuation.plan(current: current, files: [current, offline])
    #expect(plan?.candidates.count == 1 && plan?.candidates[0].url == nil)
    #expect(plan?.candidates[0].localMetadata?.sourceReachable == false)
  }
  @Test func unrelatedMoviesSourcesAndChangedCurrentMetadataCannotContinue() {
    let current = item("one", episode: 1)
    var changed = current; changed.localMetadata?.episode = 3
    #expect(EpisodeContinuation.plan(current: current, files: [changed, item("two", episode: 2)]) == nil)
    var plugin = current; plugin.source = "example"
    #expect(EpisodeContinuation.plan(current: plugin, files: [plugin, item("two", episode: 2)]) == nil)
    #expect(EpisodeContinuation.plan(current: MediaItem(id: "movie", title: "电影"), files: [current]) == nil)
    var failed = item("two", episode: 2); failed.localMetadata?.metadataReadFailed = true
    #expect(EpisodeContinuation.plan(current: current, files: [current, failed]) == nil)
  }
  @Test func finiteVersionListAndOfflineSMBFilenameNeverExposeNamespace() {
    let current = item("one", episode: 1)
    let files = [current] + (0..<205).map { item("two-\($0)", episode: 2) }
    let plan = EpisodeContinuation.plan(current: current, files: files)
    #expect(plan?.candidates.count == 200 && plan?.limited == true && plan?.message.contains("200") == true)
    let offline = MediaItem(id: "mtv:smb:owned\nsmb://nas/Share\nuser:secret-user\nfile:Season 1/Show.S01E02.mkv", title: "离线", source: "local")
    #expect(SMBMediaIdentity.displayFilename(offline) == "Show.S01E02.mkv")
    #expect(SMBMediaIdentity.displayFilename(MediaItem(id: "opaque", title: "远程", source: "example")) == nil)
  }
}

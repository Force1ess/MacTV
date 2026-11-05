import Foundation

public struct EpisodeContinuationPlan: Sendable {
  public let currentID: String
  public let label: String
  public let message: String
  public let candidates: [MediaItem]
  public let limited: Bool
}
public enum EpisodeContinuation {
  /// Ordered local descriptions only. This never asserts that a series/season is complete.
  public static func plan(current: MediaItem, files: [MediaItem]) -> EpisodeContinuationPlan? {
    guard current.source == "local", !current.isLibraryCollection, !current.isFolder, let identity = LibraryCatalog.seriesIdentity(current),
      let origin = current.localMetadata, origin.metadataReadFailed != true,
      let season = origin.season, season >= 0, let first = origin.episode, first > 0,
      let indexed = files.first(where: { $0.id == current.id && $0.source == "local" }),
      LibraryCatalog.seriesIdentity(indexed) == identity,
      indexed.localMetadata?.season == season, indexed.localMetadata?.episode == first,
      indexed.localMetadata?.episodeEnd == origin.episodeEnd, indexed.localMetadata?.metadataReadFailed != true else { return nil }
    let end = origin.episodeEnd ?? first
    guard end >= first, end <= 9999 else { return nil }
    let episodes = files.filter {
      guard !$0.isLibraryCollection, !$0.isFolder, $0.id != current.id,
        LibraryCatalog.seriesIdentity($0) == identity, let info = $0.localMetadata,
        info.metadataReadFailed != true, let value = info.episode, value > 0 && value <= 9999,
        let number = info.season, number >= 0 && number <= 99 else { return false }
      return number == season ? value > end : number > season
    }
    guard let next = episodes.min(by: {
      let a = $0.localMetadata!, b = $1.localMetadata!
      return a.season == b.season ? a.episode! < b.episode! : a.season! < b.season!
    }), let info = next.localMetadata, let targetSeason = info.season, let targetEpisode = info.episode else { return nil }
    var seen = Set<String>()
    let choices = episodes.filter { $0.localMetadata?.season == targetSeason && $0.localMetadata?.episode == targetEpisode && seen.insert($0.id).inserted }
      .sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    let label: String, message: String
    if targetSeason != season {
      label = targetSeason == season + 1 ? "下一季" : "后续季度"
      message = "此来源索引中暂无本季后续，下面是第\(targetSeason)季第\(targetEpisode)集。未据此判断本季是否完整。"
    } else if targetEpisode != end + 1 {
      label = "下一可用集"
      let missing = targetEpisode == end + 2 ? "第\(end + 1)集" : "第\(end + 1)至\(targetEpisode - 1)集"
      message = "索引中未确认\(missing)，下面是第\(targetEpisode)集。请确认后继续。"
    } else {
      label = "下一集"
      message = choices.count > 1 ? "本集有多个文件，请选择要播放的版本。" : ""
    }
    let limited = choices.count > 200
    return EpisodeContinuationPlan(currentID: current.id, label: label,
      message: message + (limited ? " 文件较多，仅显示前200项；可返回来源查找其它版本。" : ""), candidates: Array(choices.prefix(200)), limited: limited)
  }
}

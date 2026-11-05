import Foundation

public struct LocalMediaMetadata: Codable, Hashable, Sendable {
  public var year: Int?
  public var seriesTitle: String?
  public var seriesRoot: String?
  public var season: Int?
  public var episode: Int?
  public var episodeEnd: Int?
  public var seriesOverview: String?
  public var seriesPoster: String?
  public var seriesIdentity: String?
  public var hasSidecar: Bool?
  public var sourceReachable: Bool?
  public var metadataReadFailed: Bool? = nil
  public var movieTMDBID: Int? = nil
  public var isExtra: Bool? = nil
}

public struct RecognizedFilename {
  public var title: String
  public var year: Int?
  public var seriesTitle: String?
  public var season: Int?
  public var episode: Int?
  public var episodeEnd: Int?
}

/// Conservative filename hints. They never rename media or override explicit NFO.
public enum MediaRecognition {
  private static func match(_ pattern: String, _ text: String) -> [String]? {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
      let result = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    else { return nil }
    return (0..<result.numberOfRanges).map { index in
      Range(result.range(at: index), in: text).map { String(text[$0]) } ?? ""
    }
  }
  public static func cleanTitle(_ text: String) -> String {
    text.replacingOccurrences(of: #"[._]+"#, with: " ", options: .regularExpression)
      .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(
        in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "-[]()")))
  }
  private static func withoutReleaseTags(_ text: String) -> String {
    guard
      let regex = try? NSRegularExpression(
        pattern:
          #"(?i)(?:^|[ ._\[(-])(?:480p|720p|1080p|2160p|4320p|4k|8k|blu-?ray|b[rd]rip|web-?dl|webrip|hdtv|h\.?26[45]|x26[45]|hevc|hdr10?\+?|dv|dovi)(?=$|[ ._\])\-])"#
      ),
      let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let range = Range(found.range, in: text)
    else { return text }
    return String(text[..<range.lowerBound])
  }
  public static func releaseStem(_ file: URL) -> String {
    file.deletingPathExtension().lastPathComponent
      .replacingOccurrences(of: #"-[A-Fa-f0-9]{8,64}$"#, with: "", options: .regularExpression)
      .replacingOccurrences(of: #"\([A-Fa-f0-9]{8}\)$"#, with: "", options: .regularExpression)
  }
  public static func displayStem(_ text: String) -> String {
    var value = text.replacingOccurrences(of: #"^\[[^\]]+\](?:\s+(?=\S)|(?=[A-Za-z])|(?=\[[^\]]+\]\[(?:\d{1,3}(?:\(|\])|NCOP|NCED|1080P|BDRip|HEVC)))"#, with: "", options: [.regularExpression, .caseInsensitive])
    value = value.replacingOccurrences(of: #"^\[[A-Za-z0-9 ._-]*(?:Raws|Subs|House|Group)\]"#, with: "", options: [.regularExpression, .caseInsensitive])
    for _ in 0..<8 {
      let stripped = value.replacingOccurrences(of: #"^\[(?:4K|HDR|4K_HDR|HDR10|2160P|1080P|HEVC|BDRip)[^\]]*\]"#, with: "", options: [.regularExpression, .caseInsensitive])
      if stripped == value { break }; value = stripped
    }
    return cleanTitle(withoutReleaseTags(value).replacingOccurrences(of: #"\]\s*\["#, with: " ", options: .regularExpression))
  }
  public static func isExtra(_ file: URL) -> Bool {
    let text = releaseStem(file)
    let directory = file.deletingLastPathComponent().lastPathComponent
    // Blu-ray explosion galleries carry both a dedicated directory and a
    // qualifier after [release group][show title]. A title named Explosion,
    // or an ordinary numbered show in such a folder, is not enough.
    let explosionGallery = match(#"^(?:Explosions?|爆炸|爆破片段|爆発シーン集)$"#, directory) != nil
      && match(#"^\[[^\]]+\]\[[^\]]+\]\[Explosion\]\[\d{1,3}\]"#, text) != nil
    return match(#"\[(?:NCOP\d*|NCED\d*|Menu|PV\d*|CM\d*|Tokuten)\]"#, text) != nil
      || match(#"\[\d{1,3}\((?:OAD|OVA|SP)\)\]"#, text) != nil
      || match(#"^(?:SPs?|Extras?|Bonus|NCOP&NCED|特典|花絮)$"#, directory) != nil
      || match(#" - (?:Menu|NCOP\d*|NCED\d*|PV\d*|CM\d*)(?= |\[|$)"#, text) != nil
      || explosionGallery
  }
  public static func filename(_ file: URL) -> RecognizedFilename {
    let text = releaseStem(file)
    let patterns = [
      #"^(.*?)(?<![A-Za-z0-9])S(\d{1,2})[ ._-]*E(\d{1,4})(?:[ ._-]*-[ ._-]*E?(\d{1,4}))?(?!\d)(.*)$"#,
      #"^(.*?)(?<!\d)(\d{1,2})x(\d{1,4})(?:-(\d{1,4}))?(?!\d)(.*)$"#,
      #"^(.*?)第(\d{1,2})季[ ._-]*第?(\d{1,4})集(?:-(\d{1,4}))?(.*)$"#,
    ]
    for pattern in patterns {
      if let groups = match(pattern, text), let season = Int(groups[2]),
        let episode = Int(groups[3]), episode >= 0
      {
        let end = Int(groups[4]).flatMap { $0 >= episode && $0 - episode <= 100 ? $0 : nil }
        let name = cleanTitle(withoutReleaseTags(groups[5]))
        let episodeTitle = name.isEmpty || name.range(of: #"^(?:19|20)\d{2}$"#, options: .regularExpression) != nil
          ? "第\(episode)集" : name
        return RecognizedFilename(
          title: episodeTitle,
          seriesTitle: displayStem(groups[1]), season: season, episode: episode, episodeEnd: end)
      }
    }
    // Fansub releases use bracketed episode numbers, not SxxExx. Require an
    // explicit bracket plus trailing technical tags so years/resolutions do not
    // become episodes. Leading release-group tags are not part of the show name.
    if let special = match(#"\[(\d{1,3})\((?:OAD|OVA|SP)\)\]"#, text), let number = Int(special[1]) {
      return RecognizedFilename(title: "特别篇 \(number)")
    }
    if let groups = match(#"^\[([^\]]+)\]\[([^\]]+)\]\[(\d{1,2})(?:st|nd|rd|th)\s*-\s*(\d{1,4})\]\[(?:总第|EP)\s*\d{1,4}\]"#, text),
      let season = Int(groups[3]), season > 0, let episode = Int(groups[4]), episode > 0 {
      let folder = file.deletingLastPathComponent().lastPathComponent
      let localized = match(#"^\[([^\]]+)\]\[([^\]]+)\]"#, folder).flatMap { parts in
        parts[1] == groups[1] && MetadataStore.containsChinese(parts[2])
          ? seriesTitle(parts[2], season: season) : nil
      }
      return RecognizedFilename(title: "第\(episode)集", seriesTitle: localized ?? cleanTitle(groups[2]), season: season, episode: episode)
    }
    let anime = text.replacingOccurrences(of: #"^\[[^\]]+\]\s*"#, with: "", options: .regularExpression)
    if let groups = match(#"^(.+?)[ ._-]*\[(\d{1,3})\](?:[ ._-]*\[[^\]]+\])*$"#, anime),
      let episode = Int(groups[2]), episode > 0 {
      return RecognizedFilename(title: "第\(episode)集", seriesTitle: displayStem(groups[1]), season: 1, episode: episode)
    }
    if let groups = match(#"^(.+?)[ ._-]+-[ ._-]*(\d{1,3})(?:[ ._-]*\[[^\]]+\])+$"#, anime),
      let episode = Int(groups[2]), episode > 0 {
      return RecognizedFilename(title: "第\(episode)集", seriesTitle: displayStem(groups[1]), season: 1, episode: episode)
    }
    if let groups = match(#"^(.+?)[ ._-]+-[ ._-]*(\d{1,3})[ ._-]*\(.+\)$"#, anime),
      match(#"(?:1080p|720p|2160p|x26[45]|hevc|BluRay)"#, anime) != nil,
      let episode = Int(groups[2]), episode > 0 {
      return RecognizedFilename(title: "第\(episode)集", seriesTitle: displayStem(groups[1]), season: 1, episode: episode)
    }
    let stripped = displayStem(text)
    if let regex = try? NSRegularExpression(pattern: #"(?<!\d)(?:19|20)\d{2}(?!\d)"#) {
      for found in regex.matches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped))
        .reversed()
      {
        guard let range = Range(found.range, in: stripped) else { continue }
        let prefix = cleanTitle(String(stripped[..<range.lowerBound]))
        // A leading year may be the movie title: 1917 (2019), 2001 ... (1968).
        if !prefix.isEmpty {
          return RecognizedFilename(title: cleanTitle(prefix), year: Int(stripped[range]))
        }
      }
    }
    let title = cleanTitle(stripped)
    return RecognizedFilename(title: title.isEmpty ? text : title)
  }
  /// Contextual padded episode numbers need both a year-labelled parent and
  /// corroborating adjacent episodes. Standalone movie sequel digits, years,
  /// resolutions and unrelated parent titles do not supply that evidence.
  static func numberedEpisodeCandidate(_ file: URL) -> RecognizedFilename? {
    let folder = file.deletingLastPathComponent().lastPathComponent
    let stem = releaseStem(file)
    if let parent = match(#"^(.+?)\s*[\[(]((?:18|19|20|21)\d{2})[\])](?:[ ._-].*)?$"#, folder),
      let year = Int(parent[2]),
      let parts = match(#"^(.+?)[ ._-]+(0[1-9]|[1-9][0-9]{1,2})[ ._-]+(.+)$"#, stem),
      !cleanTitle(parent[1]).isEmpty,
      cleanTitle(parts[1]).compare(cleanTitle(parent[1]), options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame,
      let episode = Int(parts[2]), !cleanTitle(parts[3]).isEmpty {
      return RecognizedFilename(title: cleanTitle(parts[3]), year: year,
        seriesTitle: cleanTitle(parent[1]), season: 1, episode: episode)
    }
    // Compact release names are only classified after checking siblings.
    guard let parts = match(#"^(.*\p{Han})[ ._-]*(\d{2})$"#, stem),
      let episode = Int(parts[2]), episode > 0 else { return nil }
    return RecognizedFilename(title: "第\(episode)集", seriesTitle: parts[1], season: 1, episode: episode)
  }
  static func numberedEpisodes(in folder: URL, filenames: Set<String>) -> [String: RecognizedFilename] {
    guard !filenames.contains(where: { $0.lowercased() == "movie.nfo" }) else { return [:] }
    var hints: [String: RecognizedFilename] = [:]
    for name in filenames where LibraryScanner.extensions.contains(URL(fileURLWithPath: name).pathExtension.lowercased()) {
      if let hint = numberedEpisodeCandidate(folder.appendingPathComponent(name)) { hints[name] = hint }
    }
    let groups = Dictionary(grouping: hints) { $0.value.seriesTitle }
    return Dictionary(uniqueKeysWithValues: groups.values.flatMap { group -> [(String, RecognizedFilename)] in
      let numbers = Set(group.compactMap { $0.value.episode })
      guard let hint = group.first?.value, let title = hint.seriesTitle else { return [] }
      let supported: Bool
      if hint.year != nil {
        supported = numbers.contains { numbers.contains($0 + 1) }
      } else {
        // Require more evidence when the enclosing folder uses a short alias.
        let minimum = folder.lastPathComponent.contains(title) ? 3 : 6
        supported = numbers.isSuperset(of: 1...minimum)
      }
      return supported ? group : []
    })
  }
  static func seriesTitle(_ name: String, season: Int) -> String {
    let title = displayStem(name).replacingOccurrences(of: #"\]\s+(?=\S)"#, with: " ", options: .regularExpression)
    let seasonMarker = #"(?i)[ ._-]+(?:S0*\#(season)\b|Season[ ._-]*0*\#(season)\b|第[一二三四五六七八九十0-9]+季)"#
    if let marker = title.range(of: seasonMarker, options: .regularExpression) {
      return cleanTitle(String(title[..<marker.lowerBound]))
    }
    return title
  }
  public static func isSeasonDirectory(_ name: String) -> Bool {
    match(#"^(?:season[ ._-]*\d{1,2}|s\d{1,2}|第\d{1,2}季|specials)$"#, name) != nil
  }
}

public struct LibraryCatalog {
  public var root: [MediaItem] = []
  public var children: [String: [MediaItem]] = [:]
  public init() {}
  public func singlePlayableEpisode(of parent: MediaItem) -> MediaItem? {
    guard parent.kind == .series || parent.kind == .season else { return nil }
    let episodes = displayedChildren(of: parent)
    guard episodes.count == 1, let episode = episodes.first, episode.url != nil else { return nil }
    return episode
  }
  public func displayedChildren(of parent: MediaItem) -> [MediaItem] {
    let values = children[parent.id] ?? []
    guard parent.kind == .series else { return values }
    return values.flatMap { $0.kind == .season ? (children[$0.id] ?? []) : [$0] }.map { original in
      var item = original
      if let season = item.localMetadata?.season, let episode = item.localMetadata?.episode {
        let number = String(format: "S%02dE%02d", season, episode)
        item.subtitle = item.kind == .versions ? original.subtitle + " · " + number : number
      }
      return item
    }
  }
  public func restoringDisplayedPath(_ ids: [String]) -> [MediaItem] {
    var level = root, structuralLevel = root, path: [MediaItem] = []
    for id in ids {
      guard let item = level.first(where: { $0.id == id }) ?? structuralLevel.first(where: { $0.id == id && $0.kind == .season }) else { break }
      path.append(item); structuralLevel = children[item.id] ?? []; level = displayedChildren(of: item)
    }
    return path
  }
  public static func seriesIdentity(_ item: MediaItem) -> String? {
    guard item.source == "local", let metadata = item.localMetadata,
      let title = metadata.seriesTitle, let root = metadata.seriesRoot,
      metadata.season != nil, metadata.episode != nil
    else { return nil }
    return metadata.seriesIdentity
      ?? (root + "\n"
        + title.folding(
          options: [.caseInsensitive, .diacriticInsensitive],
          locale: Locale(identifier: "en_US_POSIX")))
  }
  public static func build(_ files: [MediaItem]) -> LibraryCatalog {
    var catalog = LibraryCatalog()
    var groups: [String: [MediaItem]] = [:]
    var extras: [MediaItem] = []
    var rootFiles: [MediaItem] = []
    func appendVersions(_ values: [MediaItem], key: String, to output: inout [MediaItem]) {
      guard values.count > 1 else { output += values; return }
      let sorted = values.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
      let first = sorted[0], id = "mtv:versions:" + key
      output.append(MediaItem(id: id, title: first.title, subtitle: "\(sorted.count) 个版本", overview: first.overview,
        poster: sorted.lazy.compactMap { $0.poster ?? $0.localMetadata?.seriesPoster }.first,
        reference: id, kind: .versions,
        localMetadata: first.localMetadata, metadataAttribution: first.metadataAttribution,
        addedAt: values.compactMap(\.addedAt).max()))
      catalog.children[id] = sorted.enumerated().map { offset, original in
        var item = original; item.subtitle = "版本 \(offset + 1) · " + original.subtitle; return item
      }
    }
    for item in files {
      if item.localMetadata?.isExtra == true { extras.append(item); continue }
      guard let key = seriesIdentity(item)
      else {
        rootFiles.append(item)
        continue
      }
      groups[key, default: []].append(item)
    }
    var rootCards: [MediaItem] = []
    for (key, values) in Dictionary(grouping: rootFiles, by: { item in
      guard let url = item.url.flatMap(URL.init(string:)), url.isFileURL else { return item.id }
      return item.source + ":" + url.deletingLastPathComponent().path + "/" + MediaRecognition.releaseStem(url)
    }).sorted(by: { $0.key < $1.key }) {
      appendVersions(values, key: key, to: &rootCards)
    }
    catalog.root = rootCards
    for (key, episodes) in groups {
      let ordered = episodes.sorted { $0.id < $1.id }
      let first = ordered[0]
      let title = first.localMetadata!.seriesTitle!
      let seriesID = "mtv:series:" + key
      let seriesPoster = ordered.lazy.compactMap { $0.localMetadata?.seriesPoster }.first
      let seasons = Dictionary(grouping: episodes) { $0.localMetadata!.season! }
      var seasonCards: [MediaItem] = []
      for season in seasons.keys.sorted() {
        let sorted = seasons[season]!.sorted {
          let left = $0.localMetadata!.episode!
          let right = $1.localMetadata!.episode!
          return left == right
            ? $0.id.localizedStandardCompare($1.id) == .orderedAscending : left < right
        }
        let id = seriesID + "\nseason:\(season)"
        seasonCards.append(
          MediaItem(
            id: id, title: season == 0 ? "特别篇" : "第 \(season) 季",
            subtitle: "\(sorted.count) 个视频", overview: first.localMetadata?.seriesOverview ?? "",
            poster: seriesPoster ?? sorted.lazy.compactMap(\.poster).first, reference: id, kind: .season,
            localMetadata: sorted.contains(where: { $0.localMetadata?.metadataReadFailed == true }) ? LocalMediaMetadata(metadataReadFailed: true) : nil,
            metadataAttribution: first.metadataAttribution, addedAt: sorted.compactMap(\.addedAt).max())
        )
        var episodeCards: [MediaItem] = []
        let variants = Dictionary(grouping: sorted) { "\($0.localMetadata!.episode!):\($0.localMetadata!.episodeEnd ?? $0.localMetadata!.episode!)" }
        var seen = Set<String>()
        for episode in sorted {
          let key = "\(episode.localMetadata!.episode!):\(episode.localMetadata!.episodeEnd ?? episode.localMetadata!.episode!)"
          if seen.insert(key).inserted { appendVersions(variants[key]!, key: id + ":" + key, to: &episodeCards) }
        }
        catalog.children[id] = episodeCards
      }
      let episodeCount = Set(episodes.map { "\($0.localMetadata!.season!):\($0.localMetadata!.episode!):\($0.localMetadata!.episodeEnd ?? $0.localMetadata!.episode!)" }).count
      let seasonLabel: String
      if seasons.count == 1, let season = seasons.keys.first {
        seasonLabel = season == 0 ? L("特别篇") : L("第 \(season) 季")
      } else {
        seasonLabel = L("\(seasons.count) 季")
      }
      catalog.root.append(
        MediaItem(
          id: seriesID, title: title,
          subtitle: seasonLabel + " · " + L("\(episodeCount) 集"),
          overview: first.localMetadata?.seriesOverview ?? "选择季，浏览并播放剧集。",
          poster: seriesPoster ?? ordered.lazy.compactMap(\.poster).first, reference: seriesID,
          kind: .series, localMetadata: episodes.contains(where: { $0.localMetadata?.metadataReadFailed == true }) ? LocalMediaMetadata(metadataReadFailed: true) : nil,
          metadataAttribution: first.metadataAttribution, addedAt: episodes.compactMap(\.addedAt).max()))
      catalog.children[seriesID] = seasonCards
    }
    if !extras.isEmpty {
      let id = "mtv:library:extras"
      catalog.root.append(MediaItem(id: id, title: "附加内容", subtitle: "\(extras.count) 个视频", reference: id, kind: .extras))
      catalog.children[id] = extras.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }
    catalog.root.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    return catalog
  }
}

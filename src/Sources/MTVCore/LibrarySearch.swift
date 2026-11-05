import Foundation

public struct LibrarySearch: Sendable {
  private let terms: [String]
  public init(_ query: String) {
    terms = Self.normalized(query).split(whereSeparator: \.isWhitespace).map(String.init)
  }
  private static func normalized(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "zh_Hans_CN"))
  }
  public func matches(_ item: MediaItem, sourceTitle: String) -> Bool {
    var fields = [item.title, item.subtitle, item.overview, sourceTitle]
    if let metadata = item.localMetadata {
      fields.append(metadata.seriesTitle ?? "")
      if let year = metadata.year { fields.append(String(year)) }
      if let season = metadata.season, let episode = metadata.episode {
        fields.append(String(format: "S%02dE%02d", season, episode))
      }
    }
    let haystack = Self.normalized(fields.joined(separator: "\n"))
    return terms.allSatisfy { haystack.contains($0) }
  }
}

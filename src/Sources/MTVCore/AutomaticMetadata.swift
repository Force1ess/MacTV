import Foundation

public struct AutomaticMetadataTarget: Identifiable {
  public let item: MediaItem
  public let kind: MetadataKind
  public let year: Int?
  public var id: String { item.id }
  public var provider: MetadataProvider { kind == .movie ? .tmdb : .tvmaze }
}

public enum AutomaticMetadata {
  public static func targets(files: [MediaItem], matches: [String: MetadataMatch])
    -> [AutomaticMetadataTarget]
  {
    let catalog = LibraryCatalog.build(files)
    return catalog.root.flatMap { $0.kind == .versions ? Array((catalog.children[$0.id] ?? []).prefix(1)) : [$0] }.compactMap { item in
      guard item.source == "local", matches[item.id] == nil else { return nil }
      if item.kind == .series {
        let members = files.filter {
          LibraryCatalog.seriesIdentity($0).map { "mtv:series:" + $0 } == item.id
        }
        guard !members.isEmpty, members.allSatisfy({ $0.localMetadata?.hasSidecar == false }) else {
          return nil
        }
        let years = Set(members.compactMap { $0.localMetadata?.year })
        guard years.count <= 1 else { return nil }
        return AutomaticMetadataTarget(item: item, kind: .series, year: years.first)
      }
      guard !item.isLibraryCollection, item.localMetadata?.hasSidecar == false else { return nil }
      return AutomaticMetadataTarget(item: item, kind: .movie, year: item.localMetadata?.year)
    }
  }
  public static func normalized(_ text: String) -> String {
    text.folding(
      options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
      locale: Locale(identifier: "en_US_POSIX")
    )
    .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
  }
  private static func matchesTitle(_ candidate: MetadataCandidate, query: String) -> Bool {
    if normalized(candidate.title) == query || candidate.originalTitle.map(normalized) == query
      || (candidate.officialAliases ?? []).map(normalized).contains(query) { return true }
    // A localized official alias may introduce a one-word abbreviation before
    // a subtitle. Never truncate primary titles or ordinary franchise names.
    guard candidate.provider == .tvmaze, (6...32).contains(query.count),
      !normalized(candidate.title).hasPrefix(query) else { return false }
    return (candidate.officialAliases ?? []).contains { alias in
      guard let colon = alias.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
      let short = alias[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
      guard !short.isEmpty, short.unicodeScalars.allSatisfy(CharacterSet.alphanumerics.contains) else { return false }
      return normalized(short) == query
    }
  }
  /// A fuzzy provider result is never enough: require exact title plus year for movies.
  public static func uniqueMatch(target: AutomaticMetadataTarget, candidates: [MetadataCandidate])
    -> MetadataCandidate?
  {
    let query = normalized(target.item.title)
    guard !query.isEmpty, target.kind != .movie || target.year != nil else { return nil }
    let exact = candidates.filter { candidate in
      guard candidate.kind == target.kind, candidate.provider == target.provider,
        matchesTitle(candidate, query: query)
      else { return false }
      return target.year == nil || candidate.year == target.year
    }
    let unique = Dictionary(grouping: exact, by: \.id)
    guard unique.count == 1, let candidate = unique.values.first?.first,
      (try? candidate.validate()) != nil
    else { return nil }
    return candidate
  }
}

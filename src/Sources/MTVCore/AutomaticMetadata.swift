import Foundation

public struct AutomaticMetadataTarget: Identifiable {
  public let item: MediaItem
  public let kind: MetadataKind
  public let year: Int?
  public var id: String { item.id }
}

public enum AutomaticMetadata {
  public static func targets(files: [MediaItem], matches: [String: MetadataMatch])
    -> [AutomaticMetadataTarget]
  {
    let catalog = LibraryCatalog.build(files)
    var seriesMembers: [String: [MediaItem]] = [:]
    for file in files {
      if let identity = LibraryCatalog.seriesIdentity(file) {
        seriesMembers["mtv:series:" + identity, default: []].append(file)
      }
    }
    return catalog.root.flatMap { $0.kind == .versions ? Array((catalog.children[$0.id] ?? []).prefix(1)) : [$0] }.compactMap { item in
      guard item.source == "local", matches[item.id] == nil else { return nil }
      if item.kind == .series {
        let members = seriesMembers[item.id] ?? []
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
  public static func uniqueMatch(target: AutomaticMetadataTarget, candidates: [MetadataCandidate])
    -> MetadataCandidate?
  {
    select(title: target.item.title, target: target, candidates: candidates)
  }

  private static func select(title: String, target: AutomaticMetadataTarget, candidates: [MetadataCandidate])
    -> MetadataCandidate?
  {
    let query = normalized(title)
    guard !query.isEmpty else { return nil }
    // Numeric titles and very short movie titles need an independent year.
    if target.kind == .movie, target.year == nil,
      (query.count < 3 || !query.unicodeScalars.contains(where: CharacterSet.letters.contains)) { return nil }
    let exact = candidates.filter { candidate in
      candidate.kind == target.kind && matchesTitle(candidate, query: query)
        && (target.year == nil || candidate.year == target.year)
    }
    let unique = Dictionary(grouping: exact, by: \.id)
    guard unique.count == 1, let candidate = unique.values.first?.first,
      (target.kind != .movie || target.year != nil || (candidate.year != nil && candidate.poster != nil)),
      (try? candidate.validate()) != nil else { return nil }
    return candidate
  }

  private static func queries(_ title: String) -> [String] {
    // Release names often carry two independent titles. Keep the complete
    // title as the first choice and split only at an explicit script boundary.
    guard let boundary = title.range(of: #"(?<=\p{Han})[ ]+(?=\p{Latin})"#, options: .regularExpression) else {
      return [title]
    }
    return [title, String(title[..<boundary.lowerBound]), String(title[boundary.upperBound...])]
  }

  public static func resolve(
    target: AutomaticMetadataTarget, client: any MetadataSearching, token: String?
  ) async throws -> MetadataCandidate? {
    let providers: [MetadataProvider] = target.kind == .movie ? [.tmdb] : (token == nil ? [.tvmaze] : [.tmdb, .tvmaze])
    var firstError: Error?
    var completedSearch = false
    for provider in providers {
      for query in queries(target.item.title) {
        do {
          let candidates = try await client.search(query: query, kind: target.kind, provider: provider,
            token: provider == .tmdb ? token : nil)
          completedSearch = true
          if let candidate = select(title: query, target: target,
            candidates: candidates.filter { $0.provider == provider }), candidate.poster != nil {
            return candidate
          }
        } catch {
          try Task.checkCancellation()
          if firstError == nil { firstError = error }
          break
        }
      }
    }
    if !completedSearch, let firstError { throw firstError }
    return nil
  }
}

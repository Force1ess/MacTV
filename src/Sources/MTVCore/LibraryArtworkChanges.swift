import Foundation

public enum LibraryArtworkChanges {
  public static func localURLs(in items: [MediaItem]) -> Set<URL> {
    var result = Set<URL>()
    for item in items {
      for address in [item.poster, item.localMetadata?.seriesPoster].compactMap({ $0 }) {
        guard let url = URL(string: address), url.isFileURL else { continue }
        result.insert(url.standardizedFileURL)
        result.formUnion(LocalArtworkCandidates.backdrops(in: url.deletingLastPathComponent()).map(\.standardizedFileURL))
      }
    }
    return result
  }
  public static func changed(previous: LibraryIncrementalState?, current: LibraryIncrementalState?,
    oldItems: [MediaItem], newItems: [MediaItem], force: Bool = false) -> Set<URL> {
    let urls = localURLs(in: oldItems + newItems)
    guard !force, let previous, let current, previous.root == current.root else { return urls }
    let old = Dictionary(previous.manifest.dependencies.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    let new = Dictionary(current.manifest.dependencies.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    return Set(urls.filter { url in
      guard let before = old[url.path], let after = new[url.path] else { return true }
      return before != after
    })
  }
}

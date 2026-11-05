import Foundation

public struct LibraryInventoryIssue: Codable, Sendable {
  public let code: String
  public let severity: String
  public let itemIDs: [String]
  public let message: String
}
public struct LibraryInventorySummary: Codable, Sendable {
  public let files: Int, rootCards: Int, series: Int, movies: Int
  public let versionCollections: Int, extraFiles: Int, missingPosters: Int
  public let unparsedEpisodes: Int, malformedTitles: Int, unreachableFiles: Int
}
/// The same catalog and metadata overlay used by the app, exposed without an
/// HTTP listener. No media mutation, credential access or network request.
public struct LibraryInventoryReport: Codable, Sendable {
  public let schema: Int
  public let sourcePath: String
  public let basis: String
  public let summary: LibraryInventorySummary
  public let rootCards: [MediaItem]
  public let collections: [String: [MediaItem]]
  public let displayCollections: [String: [MediaItem]]
  public let files: [MediaItem]
  public let issues: [LibraryInventoryIssue]
  public let checkPassed: Bool
  public init(root: URL, basis: String, files raw: [MediaItem], matches: [String: MetadataMatch] = [:]) {
    schema = 1
    sourcePath = root.standardizedFileURL.path; self.basis = basis
    files = MetadataStore.apply(matches, to: raw).sorted { $0.id < $1.id }
    let catalog = LibraryCatalog.build(files)
    rootCards = catalog.root; collections = catalog.children
    var display: [String: [MediaItem]] = [:]
    for item in catalog.root + catalog.children.values.flatMap({ $0 }) where item.isLibraryCollection {
      display[item.id] = catalog.displayedChildren(of: item)
    }
    displayCollections = display
    let graph = display
    var issues: [LibraryInventoryIssue] = []
    let missing = rootCards.filter { $0.kind != .extras && $0.poster == nil }
    if !missing.isEmpty { issues.append(.init(code: "missing-poster", severity: "warning", itemIDs: missing.map(\.id), message: "尚未获得海报，不能视为海报墙整理完成")) }
    var displayed: [String: MediaItem] = [:]
    for item in files + rootCards + catalog.children.values.flatMap({ $0 }) { displayed[item.id] = item }
    let malformed = displayed.values.filter { $0.title.contains("]") || $0.title.contains("[") }.sorted { $0.id < $1.id }
    if !malformed.isEmpty { issues.append(.init(code: "release-label-in-title", severity: "error", itemIDs: malformed.map(\.id), message: "显示标题仍含下载标签，需要重新识别或确认片名")) }
    let unparsed = files.filter { item in
      guard item.localMetadata?.episode == nil, item.localMetadata?.isExtra != true,
        let url = item.url.flatMap(URL.init(string:)) else { return false }
      return MediaRecognition.filename(url).episode != nil
    }
    if !unparsed.isEmpty { issues.append(.init(code: "episode-not-classified", severity: "error", itemIDs: unparsed.map(\.id), message: "文件名有明确集号，但索引没有剧集信息")) }
    var reachable = Set<String>(), visited = Set<String>()
    func visit(_ item: MediaItem) {
      guard visited.insert(item.id).inserted else { return }
      if item.isLibraryCollection { for child in graph[item.id] ?? [] { visit(child) } }
      else { reachable.insert(item.id) }
    }
    for item in rootCards { visit(item) }
    let unreachable = Set(files.map(\.id)).subtracting(reachable).sorted()
    if !unreachable.isEmpty { issues.append(.init(code: "unreachable-media", severity: "error", itemIDs: unreachable, message: "文件已索引但无法通过媒体卡片进入")) }
    self.issues = issues
    checkPassed = !issues.contains { $0.severity == "error" }
    summary = .init(files: files.count, rootCards: rootCards.count,
      series: rootCards.filter { $0.kind == .series }.count,
      movies: rootCards.filter { !$0.isLibraryCollection || ($0.kind == .versions && $0.localMetadata?.episode == nil) }.count,
      versionCollections: catalog.children.values.flatMap { $0 }.filter { $0.kind == .versions }.count + rootCards.filter { $0.kind == .versions }.count,
      extraFiles: files.filter { $0.localMetadata?.isExtra == true }.count,
      missingPosters: missing.count, unparsedEpisodes: unparsed.count,
      malformedTitles: malformed.count, unreachableFiles: unreachable.count)
  }
}

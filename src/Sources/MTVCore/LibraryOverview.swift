import Foundation

public struct LibraryPreviewCard: Identifiable, Sendable {
  public let id: String
  public let title: String
  public let subtitle: String
  public let poster: String?
  public let collection: Bool
  public let offline: Bool
  public let metadataReadFailed: Bool
  public var movieTMDBID: Int? = nil
  public var filename: String? = nil
}
public struct LibraryMovieVersion: Identifiable, Sendable {
  public struct ID: Hashable, Sendable { public let sourceID: UUID; public let itemID: String }
  public var id: ID { ID(sourceID: source.id, itemID: card.id) }
  public let source: SavedLibrarySource
  public let card: LibraryPreviewCard
  public init(source: SavedLibrarySource, card: LibraryPreviewCard) { self.source = source; self.card = card }
}
public struct LibraryMovieVersionResult: Sendable {
  public let versions: [LibraryMovieVersion]
  public let limited: Bool
  public let unavailableSources: [String]
}
public struct LibraryOverviewSection: Identifiable, Sendable {
  public var id: UUID { source.id }
  public let source: SavedLibrarySource
  public let cards: [LibraryPreviewCard]
  public let fileCount: Int
  public let matchingCount: Int
  public let indexedAt: Date?
  public let message: String
}

/// Reads MTV-owned descriptions only. Does not stat, scan or mount any media root.
public actor LibraryOverviewStore {
  private let sources: SavedLibrarySourcesStore
  private let local: LibraryIndexStore
  private let nas: SMBLibraryIndexStore
  private let profiles: SMBProfileStore
  public init(sources: SavedLibrarySourcesStore, local: LibraryIndexStore, nas: SMBLibraryIndexStore, profiles: SMBProfileStore) {
    self.sources = sources; self.local = local; self.nas = nas; self.profiles = profiles
  }
  private struct CachedSource {
    let items: [MediaItem]
    let date: Date?
    let message: String
    var filenames: [String: String] = [:]
  }
  private func cached(_ source: SavedLibrarySource) async throws -> CachedSource {
    if let path = source.path {
      let snapshot = try await local.load(root: URL(fileURLWithPath: path))
      return CachedSource(items: snapshot?.items ?? [], date: snapshot?.scannedAt,
        message: snapshot == nil ? "尚无索引，打开来源后扫描" : "已保存的影片资料 · 打开时检查连接")
    }
    guard let profile = try await profiles.load().first(where: { $0.id == source.smbProfileID }) else {
      throw MTVError.message("NAS 连接已移除，请在内容来源中重新配置")
    }
    let snapshot = try await nas.load(profile: profile)
    return CachedSource(items: snapshot?.offlineItems() ?? [], date: snapshot?.scannedAt,
      message: snapshot == nil ? "尚无索引，连接 NAS 后扫描" : "NAS 缓存 · 播放时检查连接",
      filenames: Dictionary((snapshot?.records ?? []).map { ($0.description.id, URL(fileURLWithPath: $0.path).lastPathComponent) }, uniquingKeysWith: { first, _ in first }))
  }
  private func card(_ item: MediaItem, source: SavedLibrarySource, filenames: [String: String]) -> LibraryPreviewCard {
    LibraryPreviewCard(id: item.id, title: String(item.title.prefix(512)), subtitle: String(item.subtitle.prefix(256)), poster: item.poster,
      collection: item.isLibraryCollection, offline: source.smbProfileID != nil || item.localMetadata?.sourceReachable == false,
      metadataReadFailed: item.localMetadata?.metadataReadFailed == true,
      movieTMDBID: !item.isLibraryCollection && item.localMetadata?.episode == nil && item.localMetadata?.metadataReadFailed != true ? item.localMetadata?.movieTMDBID : nil,
      filename: filenames[item.id] ?? item.url.flatMap(URL.init(string:)).flatMap { $0.isFileURL ? $0.lastPathComponent : nil })
  }
  /// Search the complete cached indexes, independently of query/display budget; never mount or scan media.
  public func versions(movieTMDBID: Int, preferred: LibraryMovieVersion.ID? = nil, matches: [String: MetadataMatch] = [:]) async throws -> LibraryMovieVersionResult {
    guard movieTMDBID > 0 else { throw MTVError.message("电影编号无效") }
    var values: [LibraryMovieVersion] = [], seen = Set<LibraryMovieVersion.ID>(), failures: [String] = [], limited = false
    for source in try await sources.load() {
      try Task.checkCancellation()
      do {
        let content = try await cached(source)
        if content.date == nil { failures.append(String(source.title.prefix(256))); continue }
        for item in MetadataStore.apply(matches, to: content.items) {
          try Task.checkCancellation()
          guard item.source == "local", !item.isLibraryCollection, !item.isFolder, item.localMetadata?.episode == nil, item.localMetadata?.metadataReadFailed != true,
            item.localMetadata?.movieTMDBID == movieTMDBID else { continue }
          let version = LibraryMovieVersion(source: source, card: card(item, source: source, filenames: content.filenames))
          guard seen.insert(version.id).inserted else { continue }
          if values.count < 200 { values.append(version) }
          else { limited = true; if version.id == preferred { values.removeLast(); values.append(version) } }
        }
      } catch is CancellationError { throw CancellationError() }
      catch { failures.append(String(source.title.prefix(256))) }
    }
    return LibraryMovieVersionResult(versions: values, limited: limited, unavailableSources: failures)
  }
  public func load(matches: [String: MetadataMatch] = [:], query: String = "") async throws -> [LibraryOverviewSection] {
    guard query.count <= 256 else { throw MTVError.message("搜索词请保持在 256 个字符以内") }
    let searching = !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    let search = LibrarySearch(query)
    let saved = try await sources.load()
    var result: [LibraryOverviewSection] = []
    var remaining = 10_000
    for source in saved {
      try Task.checkCancellation()
      do {
        let content = try await cached(source), items = content.items, date = content.date
        var message = content.message
        try Task.checkCancellation()
        let enriched = MetadataStore.apply(matches, to: items)
        let roots = LibraryCatalog.build(enriched).root
        let candidates = searching
          ? (roots.filter(\.isLibraryCollection) + enriched).filter { search.matches($0, sourceTitle: source.title) }
          : roots
        if searching && candidates.isEmpty { continue }
        let shown = candidates.prefix(remaining)
        let cards = shown.map { card($0, source: source, filenames: content.filenames) }
        remaining -= cards.count
        if cards.count < candidates.count { message += " · 总览显示已达上限，请打开此来源查看全部" }
        result.append(LibraryOverviewSection(source: source, cards: cards, fileCount: items.count, matchingCount: candidates.count, indexedAt: date, message: message))
      } catch is CancellationError { throw CancellationError() }
      catch {
        result.append(LibraryOverviewSection(source: source, cards: [], fileCount: 0, matchingCount: 0, indexedAt: nil,
          message: "缓存无法读取，请打开来源检查：" + error.localizedDescription))
      }
    }
    return result
  }
}

import Foundation

public enum LibraryBrowseKind: String, CaseIterable, Sendable { case all, movies, series
  public var title: String { switch self { case .all: return L("全部"); case .movies: return L("电影"); case .series: return L("剧集") } }
}
public enum LibraryBrowseOrder: String, CaseIterable, Sendable { case title, reverseTitle, newestYear, newestAdded
  public var title: String { switch self { case .title: return L("标题顺序"); case .reverseTitle: return L("标题倒序"); case .newestYear: return L("年份从新到旧"); case .newestAdded: return L("添加日期从新到旧") } }
}
public struct LibraryBrowseOptions: Equatable, Sendable {
  public var kind: LibraryBrowseKind
  public var order: LibraryBrowseOrder
  public init(kind: LibraryBrowseKind = .all, order: LibraryBrowseOrder = .title) { self.kind = kind; self.order = order }
  public func apply(_ items: [MediaItem], query: String = "", sourceTitle: String = "") -> [MediaItem] {
    let search = LibrarySearch(query)
    return items.filter { item in
      guard item.source == "local", !item.isFolder else { return false }
      let television = item.kind == .series || item.kind == .season || item.localMetadata?.episode != nil
      guard kind == .all || (kind == .series ? television : !television) else { return false }
      return search.matches(item, sourceTitle: sourceTitle)
    }.sorted { a, b in
      if order == .newestAdded, a.addedAt != b.addedAt {
        if let left = a.addedAt, let right = b.addedAt { return left > right }
        return a.addedAt != nil
      }
      if order == .newestYear {
        let left = a.localMetadata?.year, right = b.localMetadata?.year
        if left != right {
          if let left, let right { return left > right }
          return left != nil
        }
      }
      let title = a.title.localizedStandardCompare(b.title)
      if title != .orderedSame { return order == .reverseTitle ? title == .orderedDescending : title == .orderedAscending }
      return a.id.localizedStandardCompare(b.id) == .orderedAscending
    }
  }
}

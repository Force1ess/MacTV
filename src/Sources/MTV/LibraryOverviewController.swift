import Foundation
import MTVCore

@MainActor final class LibraryOverviewController: ObservableObject {
  enum Row { case actions; case source(Int); case cards(Int, Range<Int>) }
  @Published private(set) var isPresented = false
  @Published private(set) var loading = false
  @Published private(set) var sections: [LibraryOverviewSection] = []
  @Published private(set) var message = ""
  @Published private(set) var query = ""
  func setQuery(_ value: String) { query = value.trimmingCharacters(in: .whitespacesAndNewlines) }
  @Published var row = 0
  @Published var column = 0
  private(set) var rows: [Row] = [.actions]
  private var generation = UUID()
  private var operation: Task<Void, Never>?
  @Published private(set) var versionsPresented = false
  @Published private(set) var versionsLoading = false
  @Published private(set) var versions: [LibraryMovieVersion] = []
  @Published private(set) var versionsTitle = ""
  @Published private(set) var versionsMessage = ""
  @Published var versionIndex = 0
  private var versionGeneration = UUID()
  private var versionOperation: Task<Void, Never>?
  private var versionStore: LibraryOverviewStore?
  private var versionMatches: [String: MetadataMatch] = [:]
  var onOpen: ((SavedLibrarySource, String?) -> Void)?
  var onNavigationIntent: (() -> Void)?
  func present(store: LibraryOverviewStore, remember: SavedLibrarySourcesStore,
    current: LibrarySourceSelection?, title: String, matches: [String: MetadataMatch], reload: Bool) {
    TVPointerFocus.remoteInput()
    isPresented = true
    guard reload else { return }
    dismissVersions(); versionStore = store; versionMatches = matches
    operation?.cancel(); let attempt = UUID(); generation = attempt
    loading = true; message = ""; row = 0; column = 0
    sections = []; rows = [.actions]
    let requestedQuery = query
    operation = Task {
      do {
        if let current, !(try await remember.load()).contains(where: { $0.matches(current) }) {
          try Task.checkCancellation()
          try await remember.remember(current, title: title)
        }
        let values = try await store.load(matches: matches, query: requestedQuery)
        guard generation == attempt, isPresented else { return }
        sections = values; rows = [.actions]
        for (index, section) in values.enumerated() {
          rows.append(.source(index))
          for start in stride(from: 0, to: section.cards.count, by: 6) {
            rows.append(.cards(index, start..<min(start + 6, section.cards.count)))
          }
        }
        if !requestedQuery.isEmpty, let first = rows.firstIndex(where: { if case .cards = $0 { return true }; return false }) {
          row = first; column = 0
        } else { row = 0; column = requestedQuery.isEmpty ? 0 : 2 }
        loading = false
        if sections.isEmpty { message = requestedQuery.isEmpty ? "还没有保存的来源，请先在内容来源中添加影片目录或 NAS。" : "没有找到匹配内容。可以修改搜索词，或清除搜索查看全部。" }
      } catch {
        guard generation == attempt, isPresented else { return }
        loading = false; message = "无法读取来源：" + error.localizedDescription
      }
    }
  }
  func close() { dismissVersions(); isPresented = false; generation = UUID(); operation?.cancel(); operation = nil; loading = false }
  func back() { if versionsPresented { dismissVersions() } else { close() } }
  func dismissVersions() {
    onNavigationIntent?()
    versionGeneration = UUID(); versionOperation?.cancel(); versionOperation = nil
    versionsPresented = false; versionsLoading = false; versions = []; versionsMessage = ""; versionIndex = 0
  }
  func move(dx: Int, dy: Int) {
    if versionsPresented {
      guard !versionsLoading else { return }
      versionIndex = min(max(0, versionIndex + dy), versions.count); return
    }
    guard !loading else { return }
    row = min(max(0, row + dy), rows.count - 1)
    column = min(max(0, column + dx), columns(row) - 1)
  }
  func columns(_ index: Int) -> Int {
    guard rows.indices.contains(index) else { return 1 }
    switch rows[index] { case .actions: return 4; case .source: return 1; case .cards(_, let range): return range.count }
  }
  func activate() {
    onNavigationIntent?()
    if versionsPresented {
      if versionsLoading || versionIndex == versions.count { dismissVersions(); return }
      guard versions.indices.contains(versionIndex) else { return }
      let chosen = versions[versionIndex]; onOpen?(chosen.source, chosen.card.id); return
    }
    guard rows.indices.contains(row) else { return }
    if case .actions = rows[row], column == 0 { close(); return }
    guard !loading else { return }
    switch rows[row] {
    case .actions: if column == 0 { close() }
    case .source(let index): onOpen?(sections[index].source, nil)
    case .cards(let index, let range):
      guard range.contains(range.lowerBound + column) else { return }
      let source = sections[index].source, card = sections[index].cards[range.lowerBound + column]
      guard let movieID = card.movieTMDBID, movieID > 0, let store = versionStore else { onOpen?(source, card.id); return }
      let selected = LibraryMovieVersion(source: source, card: card)
      dismissVersions(); versionsPresented = true; versionsLoading = true; versionsTitle = card.title
      let attempt = versionGeneration, matches = versionMatches
      versionOperation = Task {
        do {
          let result = try await store.versions(movieTMDBID: movieID, preferred: selected.id, matches: matches)
          guard versionGeneration == attempt, isPresented, versionsPresented else { return }
          let choices = result.versions
          let selectedStillPresent = choices.contains(where: { $0.id == selected.id })
          if choices.count == 1 && selectedStillPresent && result.unavailableSources.isEmpty && !result.limited {
            dismissVersions(); onOpen?(source, card.id); return
          }
          versions = choices
          versionIndex = choices.firstIndex(where: { $0.id == selected.id }) ?? 0
          versionsLoading = false
          versionsMessage = (!selectedStillPresent ? "所选条目的资料已变化，请返回刷新总览；下方仅显示仍能确认的版本。\n" : "")
            + (result.limited ? "版本较多，仅显示200项并保留本次所选版本。可返回来源查看其它条目。\n" : "")
            + (result.unavailableSources.isEmpty ? "" : "以下来源缓存未就绪：" + result.unavailableSources.joined(separator: "、") + "。版本列表可能不完整。")
        } catch {
          guard versionGeneration == attempt, isPresented, versionsPresented else { return }
          versionsLoading = false; versionsMessage = "版本资料无法读取：" + error.localizedDescription
          versions = []; versionIndex = 0
        }
      }
    }
  }
}

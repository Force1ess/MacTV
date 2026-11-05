import Combine
import Foundation
import MTVCore

enum SavedShelf: String { case history, watchlist
  var capability: String { rawValue }
}
struct SavedContentReturn { let shelf: SavedShelf; let id: String }

@MainActor final class WatchlistController: ObservableObject {
  @Published private(set) var entries: [PlaybackHistoryContext] = []
  @Published private(set) var error: String?
  @Published var menuID: String?
  @Published var menuIndex = 0
  var onUpdate: (([PlaybackHistoryContext]) -> Void)?
  var onOpen: ((PlaybackHistoryContext) -> Void)?
  private let store: PlaybackResumeStore
  private var generation = UUID()
  private var enrichment: Task<Void, Never>?
  init(store: PlaybackResumeStore) { self.store = store; reload() }
  func reload() {
    let previous = entries
    do { entries = try store.watchlist(); error = nil }
    catch { entries = []; self.error = error.localizedDescription }
    if let menuID, !entries.contains(where: { $0.id == menuID }) { self.menuID = nil }
    onUpdate?(previous)
  }
  func contains(_ item: MediaItem) -> Bool {
    guard let id = PlaybackResumeStore.identity(for: item.id, source: item.source) else { return false }
    return entries.contains { $0.id == id }
  }
  func add(_ context: PlaybackHistoryContext, poster: (() async -> String?)? = nil) throws {
    cancelEnrichment()
    do { try store.addToWatchlist(context); reload() } catch { reload(); throw error }
    guard let poster else { return }
    let attempt = generation
    enrichment = Task {
      let address = await poster()
      guard !Task.isCancelled, generation == attempt, entries.contains(where: { $0.id == context.id }), let address else { return }
      do {
        guard try store.watchlist().first(where: { $0.id == context.id }) == context else { return }
        try store.addToWatchlist(context.replacingPoster(address)); reload()
      }
      catch { self.error = error.localizedDescription }
    }
  }
  func remove(_ id: String) {
    cancelEnrichment()
    do { try store.removeFromWatchlist(id); menuID = nil; reload() }
    catch { reload(); self.error = error.localizedDescription }
  }
  func open(_ id: String) { if let value = entries.first(where: { $0.id == id }) { menuID = nil; onOpen?(value) } }
  func menu(_ id: String) { guard entries.contains(where: { $0.id == id }) else { return }; menuID = id; menuIndex = 0 }
  func activateMenu() {
    guard let id = menuID else { return }
    switch menuIndex { case 0: open(id); case 1: remove(id); default: menuID = nil }
  }
  func cancelEnrichment() { generation = UUID(); enrichment?.cancel(); enrichment = nil }
}

extension AppModel {
  var watchlistRow: Int { continueWatching.entries.isEmpty ? 3 : 4 }
  func watchlistDidUpdate(_ previous: [PlaybackHistoryContext]) {
    savedShelvesDidUpdate(history: continueWatching.entries.map(\.context), watchlist: previous)
  }
  func savedShelvesDidUpdate(history oldHistory: [PlaybackHistoryContext], watchlist oldWatchlist: [PlaybackHistoryContext]) {
    let oldMedia = 3 + (oldHistory.isEmpty ? 0 : 1) + (oldWatchlist.isEmpty ? 0 : 1)
    let oldWatchlistRow = oldHistory.isEmpty ? 3 : 4, position = (focus.row, focus.column)
    let selected: SavedContentReturn?
    if section == .home, !oldHistory.isEmpty, position.0 == 3, oldHistory.indices.contains(position.1) {
      selected = SavedContentReturn(shelf: .history, id: oldHistory[position.1].id)
    } else if section == .home, !oldWatchlist.isEmpty, position.0 == oldWatchlistRow, oldWatchlist.indices.contains(position.1) {
      selected = SavedContentReturn(shelf: .watchlist, id: oldWatchlist[position.1].id)
    } else { selected = nil }
    rebuildFocus()
    guard section == .home else { return }
    if position.0 >= oldMedia { focus.select(row: position.0 + homeMediaOffset - oldMedia, column: position.1) }
    else if let selected {
      let values = selected.shelf == .history ? continueWatching.entries.map(\.context) : watchlist.entries
      if !values.isEmpty { focus.select(row: selected.shelf == .history ? 3 : watchlistRow,
        column: values.firstIndex(where: { $0.id == selected.id }) ?? min(position.1, values.count - 1)) }
      else { focus.select(row: !continueWatching.entries.isEmpty ? 3 : (!watchlist.entries.isEmpty ? watchlistRow : (mediaRows.isEmpty ? 2 : homeMediaOffset)), column: 0) }
    }
  }
  func canWatchlist(_ item: MediaItem) -> Bool {
    watchlist.contains(item) || (try? savedContext(for: item, capability: "watchlist")) != nil
  }
  func toggleWatchlist(_ item: MediaItem) {
    if watchlist.contains(item) {
      guard let id = PlaybackResumeStore.identity(for: item.id, source: item.source) else { return }
      watchlist.remove(id)
      if let error = watchlist.error { notice = error }
    } else {
      do {
        guard let context = try savedContext(for: item, capability: "watchlist") else { throw MTVError.message("此内容尚不支持加入待看片单") }
        if item.source == "local", let profile = captureLibrarySource().smbProfile {
          let index = smbLibraryIndex
          try watchlist.add(context) {
            guard let snapshot = try? await index.load(profile: profile) else { return nil }
            return snapshot.offlineItems().first(where: { $0.id == item.id })?.poster
          }
        } else { try watchlist.add(context) }
      } catch { notice = error.localizedDescription }
    }
    detailAction = min(detailAction, max(0, detailControls(for: item).count - 1))
  }
}

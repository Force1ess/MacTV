import Combine
import Foundation
import MTVCore

@MainActor final class ContinueWatchingController: ObservableObject {
  @Published private(set) var entries: [PlaybackHistoryEntry] = []
  @Published private(set) var error: String?
  @Published var menuID: String?
  @Published var menuIndex = 0
  @Published private(set) var recoveryPresented = false
  @Published private(set) var recoveryReview: PlaybackHistoryResetReview?
  @Published private(set) var recoveryBusy = false
  @Published private(set) var recoveryMessage = ""
  @Published var recoverySelection = 0
  private(set) var lastRecoveryBackup: URL?
  var onUpdate: (([PlaybackHistoryEntry]) -> Void)?
  var onOpen: ((PlaybackHistoryEntry) -> Void)?
  private let store: PlaybackResumeStore
  private var current: PlaybackHistoryContext?
  private var generation = UUID()
  private var lookup: Task<Void, Never>?
  private var recoveryTask: Task<Void, Never>?
  private let recoveryDirectory: URL
  init(store: PlaybackResumeStore, recoveryDirectory: URL? = nil) {
    self.store = store
    self.recoveryDirectory = recoveryDirectory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      CommandLine.arguments.contains("--ui-smoke") ? "Library/Application Support/MTV/TestResults/HistoryRecovery-" + UUID().uuidString.lowercased() : "Library/Application Support/MTV/HistoryRecovery")
    reload()
  }
  func reload() {
    let previous = entries
    do { entries = try store.recent(); error = nil }
    catch { entries = []; self.error = error.localizedDescription }
    if let menuID, !entries.contains(where: { $0.id == menuID }) { self.menuID = nil }
    onUpdate?(previous)
  }
  func begin(_ context: PlaybackHistoryContext?, poster: (() async -> String?)? = nil) {
    end(); current = context; let attempt = generation
    guard let context, let poster else { return }
    lookup = Task {
      let value = await poster()
      guard !Task.isCancelled, generation == attempt, current?.id == context.id, let value,
        let enriched = try? context.replacingPoster(value) else { return }
      current = enriched
    }
  }
  func end() { generation = UUID(); lookup?.cancel(); lookup = nil; current = nil }
  func saved() {
    do { if let current { try store.remember(current) }; reload() }
    catch { let previous = entries; entries = []; self.error = error.localizedDescription; onUpdate?(previous) }
  }
  func report(_ message: String) { error = message }
  func open(_ id: String) { if let entry = entries.first(where: { $0.id == id }) { menuID = nil; onOpen?(entry) } }
  func remove(_ id: String) {
    do { try store.forgetHistory(id); menuID = nil; reload() } catch { self.error = error.localizedDescription }
  }
  func menu(_ id: String) { guard entries.contains(where: { $0.id == id }) else { return }; menuIndex = 0; menuID = id }
  func activateMenu() {
    guard let id = menuID else { return }
    switch menuIndex { case 0: open(id); case 1: remove(id); default: menuID = nil }
  }
  func presentRecovery() {
    guard !recoveryBusy else { return }
    menuID = nil; recoverySelection = 0; recoveryPresented = true; lastRecoveryBackup = nil
    do {
      recoveryReview = try store.reviewHistoryReset()
      recoveryMessage = recoveryReview?.isDamaged == true ? "当前观看列表无法读取。" : "当前保存了 \(recoveryReview?.recordCount ?? 0) 条观看卡片。"
    } catch { recoveryReview = nil; recoveryMessage = error.localizedDescription }
  }
  func closeRecovery() {
    recoveryPresented = false
    // A confirmed recovery finishes its atomic backup/write even after leaving.
    if !recoveryBusy { recoveryReview = nil }
  }
  func activateRecovery() {
    guard !recoveryBusy else { return }
    guard recoverySelection == 1, let review = recoveryReview else { closeRecovery(); return }
    recoveryBusy = true; recoveryMessage = "正在保留原始备份…"
    let directory = recoveryDirectory
    recoveryTask = Task {
      do {
        let backup = try await Task.detached(priority: .utility) { try review.writeBackup(in: directory) }.value
        try store.commitHistoryReset(backup)
        lastRecoveryBackup = backup.url; recoveryReview = nil; recoverySelection = 0
        recoveryMessage = "观看列表已重建，原始备份已保存。播放进度仍然保留，之后观看会重新生成卡片。"
        reload()
      } catch { recoveryReview = nil; recoverySelection = 0; recoveryMessage = error.localizedDescription }
      recoveryBusy = false; recoveryTask = nil
    }
  }
  func waitForRecovery() async { await recoveryTask?.value }
}

extension AppModel {
  var homeMediaOffset: Int { 3 + (continueWatching.entries.isEmpty ? 0 : 1) + (watchlist.entries.isEmpty ? 0 : 1) }
  var mediaFocusOffset: Int { section == .home ? homeMediaOffset : (hasBilibiliTabs ? bilibiliChannelRow : moduleToolbarRow) + 1 }
  func historyDidUpdate(_ previous: [PlaybackHistoryEntry]) {
    savedShelvesDidUpdate(history: previous.map(\.context), watchlist: watchlist.entries)
  }
  func hasSavedContent(_ id: String, shelf: SavedShelf) -> Bool {
    shelf == .history ? continueWatching.entries.contains { $0.id == id } : watchlist.entries.contains { $0.id == id }
  }
  func savedContext(for item: MediaItem, capability: String) throws -> PlaybackHistoryContext? {
    guard !item.isFolder, !item.isLibraryCollection else { return nil }
    let source = captureLibrarySource()
    var selection: LibrarySourceSelection?
    let reference: String?
    let title: String
    if item.source == "local" {
      guard library.contains(where: { $0.id == item.id }) else { return nil }
      if let profile = source.smbProfile { selection = LibrarySourceSelection(smbProfileID: profile.id); title = "NAS" }
      else if source.boundary == nil, !source.path.isEmpty {
        selection = LibrarySourceSelection(path: source.path); title = URL(fileURLWithPath: source.path).lastPathComponent
      } else { return nil }
      reference = nil
    } else {
      guard let plugin = plugins.first(where: { $0.id == item.source }), plugin.isAvailable,
        plugin.manifest.capabilities.contains(capability), plugin.manifest.capabilities.contains("resolve") else { return nil }
      reference = item.reference ?? item.id; title = plugin.title
    }
    var poster = item.poster
    if let address = poster, let url = URL(string: address) {
      if url.user != nil || url.password != nil || url.query != nil || url.fragment != nil { poster = nil }
      let prefix = selection?.path == "/" ? "/" : (selection?.path ?? "") + "/"
      if url.isFileURL, selection?.path == nil || !url.standardizedFileURL.path.hasPrefix(prefix) { poster = nil }
    }
    return try PlaybackHistoryContext(mediaID: item.id, sourceID: item.source, title: String(item.title.prefix(512)),
      subtitle: String(item.subtitle.prefix(512)), sourceTitle: title.isEmpty ? "影片库" : String(title.prefix(256)),
      poster: poster, reference: reference, collectionReference: item.source == "local" ? nil : item.collectionReference, librarySource: selection)
  }
  func beginHistoryForPlayback(_ item: MediaItem) {
    do {
      guard let context = try savedContext(for: item, capability: "history") else { continueWatching.begin(nil); return }
      if let profile = captureLibrarySource().smbProfile, item.source == "local" {
        let index = smbLibraryIndex
        continueWatching.begin(context) {
          guard let snapshot = try? await index.load(profile: profile) else { return nil }
          return snapshot.offlineItems().first(where: { $0.id == item.id })?.poster
        }
      } else { continueWatching.begin(context) }
    } catch { continueWatching.begin(nil); continueWatching.report(error.localizedDescription) }
  }
  func historyPoster(_ entry: PlaybackHistoryEntry) -> String? { savedContentPoster(entry.context, capability: "history") }
  func savedContentPoster(_ context: PlaybackHistoryContext, capability: String) -> String? {
    guard let address = context.poster, let url = URL(string: address) else { return nil }
    if context.sourceID == "local" { return address }
    guard let plugin = plugins.first(where: { $0.id == context.sourceID }), plugin.isAvailable,
      plugin.manifest.capabilities.contains(capability), NetworkPolicy.permitsPlayback(url, domains: plugin.manifest.artworkDomains ?? []) else { return nil }
    return address
  }
  func closeHistoryDetail() {
    detail = nil
    guard let destination = savedContentReturn else { return }
    savedContentReturn = nil; navigate(.home)
    let values = destination.shelf == .history ? continueWatching.entries.map(\.context) : watchlist.entries
    if let index = values.firstIndex(where: { $0.id == destination.id }) {
      focus.select(row: destination.shelf == .history ? 3 : watchlistRow, column: index)
    } else { focus.select(row: 2, column: 0) }
  }
}

import Foundation
import MTVCore

@MainActor final class SavedSourcesController: ObservableObject {
  @Published private(set) var isPresented = false
  @Published private(set) var loading = false
  @Published private(set) var sources: [SavedLibrarySource] = []
  @Published var selection = 0
  @Published var column = 0
  @Published var message = ""
  var current: LibrarySourceSelection?
  var store = SavedLibrarySourcesStore(file: LibrarySourceStore.normalFile.deletingPathExtension().appendingPathExtension("saved.json"))
  var onSelect: ((LibrarySourceSelection, String) -> Void)?
  var onAddLocal: (() -> Void)?
  var onAddNAS: (() -> Void)?
  var onWillRemove: (() async -> Void)?
  var onRemoved: ((SavedLibrarySource, [SavedLibrarySource]) -> Void)?
  private var operation: Task<Void, Never>?
  private var pendingRemoval: Task<Void, Never>?
  private var generation = UUID()
  var rowCount: Int { sources.count + 3 }
  func rowID(_ row: Int) -> String {
    if sources.indices.contains(row) { return "source-" + sources[row].id.uuidString }
    return "action-\(row - sources.count)"
  }
  func present(current: LibrarySourceSelection?, title: String) {
    close()
    TVPointerFocus.remoteInput()
    isPresented = true; loading = true; selection = 0; column = 0; message = ""
    self.current = current
    let attempt = generation
    let store = store
    let pending = pendingRemoval
    operation = Task {
      do {
        await pending?.value
        guard generation == attempt, isPresented else { return }
        var values = try await store.load()
        guard generation == attempt, isPresented else { return }
        if let current, (current.path != nil || current.smbProfileID != nil),
          !values.contains(where: { $0.matches(current) }) {
          values = try await store.remember(current, title: title)
        }
        guard generation == attempt, isPresented else { return }
        sources = values; loading = false
        selection = current.flatMap { active in values.firstIndex { $0.matches(active) } } ?? 0
      } catch {
        guard generation == attempt, isPresented else { return }
        loading = false; message = "来源清单无法读取：" + error.localizedDescription
      }
    }
  }
  func move(_ step: Int) {
    guard !loading else { return }
    selection = min(max(0, selection + step), rowCount - 1)
    column = 0
  }
  func moveColumn(_ step: Int) {
    guard !loading, sources.indices.contains(selection) else { return }
    column = min(max(0, column + step), 1)
  }
  func activate() {
    guard !loading else { return }
    if sources.indices.contains(selection) {
      let source = sources[selection]
      if column == 1 { requestRemoval(); return }
      if let current, source.matches(current) { close(); return }
      close(); onSelect?(source.selection, source.title)
    } else {
      let action = selection - sources.count
      close()
      if action == 0 { onAddLocal?() }
      if action == 1 { onAddNAS?() }
    }
  }
  private func requestRemoval() {
    guard !loading, sources.indices.contains(selection) else { return }
    let source = sources[selection]
    let attempt = generation
    let store = store
    let previous = pendingRemoval
    loading = true; message = ""
    pendingRemoval = Task {
      await previous?.value
      do {
        await self.onWillRemove?()
        let values = try await store.remove(source.id)
        if let current, source.matches(current) { self.current = nil }
        if generation == attempt, isPresented {
          sources = values
          selection = min(selection, values.count)
          column = 0; loading = false
        }
        self.onRemoved?(source, values)
      } catch {
        guard generation == attempt, isPresented else { return }
        loading = false; message = error.localizedDescription
      }
    }
  }
  func back() { close() }
  func close() {
    generation = UUID(); operation?.cancel(); operation = nil
    isPresented = false; sources = []; loading = false
  }
  func waitForPendingChanges() async { await pendingRemoval?.value }
}

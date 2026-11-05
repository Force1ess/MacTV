import Foundation
import MTVCore

enum LocalFolderControl: Equatable {
  case use, parent, home, movies, volumes, address, systemPicker, close
  case folder(URL)
}

@MainActor final class LocalFolderController: ObservableObject {
  var title = "选择影片文件夹"
  var shortcutTitle = L("Movies Folder")
  var shortcutURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
  @Published private(set) var isPresented = false
  @Published private(set) var loading = false
  @Published private(set) var directory: URL?
  @Published private(set) var folders: [URL] = []
  @Published private(set) var total = 0
  @Published private(set) var message = ""
  @Published var selection = 0
  var onSelect: ((URL) -> Void)?
  var onAddress: (() -> Void)?
  var onSystemPicker: (() -> Void)?
  var onDismiss: (() -> Void)?
  private var generation = UUID()
  private var timeout: Task<Void, Never>?
  private var browseHistory: [URL] = []
  var controls: [LocalFolderControl] {
    if loading { return [.close] }
    return (directory == nil ? [] : [.use, .parent])
      + [.home, .movies, .volumes, .address, .systemPicker, .close]
      + folders.map(LocalFolderControl.folder)
  }
  func present(at url: URL) {
    close(notify: false)
    browseHistory = []
    isPresented = true
    directory = nil
    browse(url)
  }
  var sidebarCount: Int { loading ? 1 : (directory == nil ? 6 : 8) }
  func move(_ delta: Int) {
    let first = selection < sidebarCount ? 0 : sidebarCount
    let last = selection < sidebarCount ? sidebarCount - 1 : controls.count - 1
    selection = min(max(first, selection + delta), last)
  }
  func moveColumn(_ delta: Int) {
    if delta < 0 { selection = 0 }
    if delta > 0, controls.count > sidebarCount { selection = sidebarCount }
  }
  func activate() {
    guard controls.indices.contains(selection) else { return }
    switch controls[selection] {
    case .use:
      guard let directory else { return }
      close(notify: false)
      onSelect?(directory)
    case .parent:
      if let directory { browse(directory.deletingLastPathComponent()) }
    case .home: browse(FileManager.default.homeDirectoryForCurrentUser)
    case .movies: browse(shortcutURL)
    case .volumes: browse(URL(fileURLWithPath: "/Volumes", isDirectory: true))
    case .address: onAddress?()
    case .systemPicker:
      close(notify: false)
      onSystemPicker?()
    case .close: close()
    case .folder(let url): browse(url)
    }
  }
  func openAddress(_ text: String) {
    do { browse(try LocalFolders.address(text)) } catch { message = error.localizedDescription }
  }
  func back() {
    if let previous = browseHistory.popLast() { browse(previous, remember: false) }
    else { close() }
  }
  func browse(_ url: URL, remember: Bool = true) {
    if remember, let directory, directory.standardizedFileURL != url.standardizedFileURL {
      browseHistory.append(directory)
    }
    timeout?.cancel()
    let attempt = UUID()
    generation = attempt
    loading = true
    message = ""
    selection = 0
    timeout = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(15)) } catch { return }
      guard let self, self.generation == attempt else { return }
      self.generation = UUID()
      self.loading = false
      self.message = "读取目录超时。检查磁盘连接或处理 macOS 的访问提示后再试。"
    }
    Task {
      do {
        let listing = try await Task.detached(priority: .utility) { try LocalFolders.list(url) }
          .value
        guard generation == attempt, isPresented else { return }
        timeout?.cancel()
        directory = listing.directory
        folders = listing.folders
        total = listing.total
        loading = false
        selection = folders.isEmpty ? 0 : 8
      } catch {
        guard generation == attempt, isPresented else { return }
        timeout?.cancel()
        loading = false
        message = L("无法读取 \(url.path)\n\(error.localizedDescription)\n请检查磁盘连接与文件访问权限，然后重试。")
      }
    }
  }
  func close(notify: Bool = true) {
    let wasPresented = isPresented
    timeout?.cancel()
    timeout = nil
    generation = UUID()
    loading = false
    isPresented = false
    browseHistory = []
    selection = 0
    if wasPresented && notify { onDismiss?() }
  }
}

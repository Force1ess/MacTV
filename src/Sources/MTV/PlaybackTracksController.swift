import Foundation
import MTVCore

enum PlaybackTrackKind { case audio, subtitles
  var title: String { self == .audio ? L("音轨") : L("字幕") }
}
struct PlaybackTrackOption: Identifiable {
  enum ID: Hashable { case track(Int32), subtitle(URL) }
  let id: ID
  let title: String
  var subtitle: LocalSubtitleCandidate? = nil
  var detail = ""
  var trackID: Int32? { if case .track(let value) = id { return value }; return nil }
  init(id: Int32, title: String) { self.id = .track(id); self.title = title }
  init(subtitle: LocalSubtitleCandidate, detail: String) { self.id = .subtitle(subtitle.url); title = subtitle.filename; self.subtitle = subtitle; self.detail = detail }
}
struct PlaybackTrackMenu { var options: [PlaybackTrackOption]; let selectedID: Int32; var limited = false; var selectedExternalURL: URL? = nil; var message = "" }

@MainActor final class PlaybackTracksController: ObservableObject {
  @Published private(set) var isPresented = false
  @Published private(set) var loading = false
  @Published private(set) var busy = false
  @Published private(set) var kind: PlaybackTrackKind = .audio
  @Published private(set) var options: [PlaybackTrackOption] = []
  @Published private(set) var selectedID: Int32 = -1
  @Published private(set) var selectedExternalURL: URL?
  @Published private(set) var message = ""
  @Published var selection = 0
  private var generation = UUID()
  var requestID: String { generation.uuidString }
  private var operation: Task<Void, Never>?
  private var apply: (@MainActor (PlaybackTrackOption) async -> Bool)?
  var onDismiss: (() -> Void)?
  func present(_ kind: PlaybackTrackKind, load: @escaping @MainActor () async throws -> PlaybackTrackMenu,
    apply: @escaping @MainActor (PlaybackTrackOption) async -> Bool) {
    close(notify: false); TVPointerFocus.remoteInput()
    self.kind = kind; self.apply = apply; isPresented = true; loading = true
    let attempt = generation
    operation = Task {
      do {
        let menu = try await load()
        guard generation == attempt, isPresented, !Task.isCancelled else { return }
        options = Array(menu.options.prefix(321)); selectedID = menu.selectedID; selectedExternalURL = menu.selectedExternalURL
        selection = options.firstIndex { isSelected($0) } ?? 0
        loading = false
        message = menu.message
        if menu.limited { message += (message.isEmpty ? "" : "\n") + L("可选项较多，仅显示部分条目。") }
        else if message.isEmpty && (options.isEmpty || (kind == .subtitles && options.count == 1 && options[0].trackID == -1)) {
          message = L("此片源没有可选的\(kind.title)。")
        }
      } catch {
        guard generation == attempt, isPresented else { return }
        loading = false; message = L("无法读取\(kind.title)：\(error.localizedDescription)")
      }
    }
  }
  func move(_ step: Int) { guard !loading, !busy else { return }; selection = min(max(0, selection + step), options.count) }
  func activate() {
    guard !busy else { return }
    guard !loading, options.indices.contains(selection), let apply else { close(); return }
    let option = options[selection], attempt = generation
    busy = true; message = ""
    operation = Task {
      guard !Task.isCancelled else { return }
      let accepted = await apply(option)
      guard generation == attempt, isPresented, !Task.isCancelled else { return }
      busy = false
      if accepted { close() }
      else { message = L("未能应用此\(kind.title)。可以重新选择或返回播放。") }
    }
  }
  func isSelected(_ option: PlaybackTrackOption) -> Bool {
    if let subtitle = option.subtitle { return subtitle.url == selectedExternalURL }
    return selectedExternalURL == nil && option.trackID == selectedID
  }
  func close(notify: Bool = true) {
    let presented = isPresented
    generation = UUID(); operation?.cancel(); operation = nil; apply = nil
    isPresented = false; loading = false; busy = false; options = []; message = ""; selection = 0
    if presented && notify { onDismiss?() }
  }
}

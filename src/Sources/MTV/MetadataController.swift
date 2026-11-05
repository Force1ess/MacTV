import Foundation
import MTVCore

@MainActor final class MetadataController: ObservableObject {
  @Published private(set) var target: MediaItem?
  @Published var query = ""
  @Published var provider = MetadataProvider.tvmaze
  @Published private(set) var candidates: [MetadataCandidate] = []
  @Published private(set) var loading = false
  @Published private(set) var message = ""
  @Published var selection = 0
  var client: any MetadataSearching = MetadataClient()
  var tmdbToken: String?
  var tokenStore = MetadataTokenStore()
  var onEditQuery: (() -> Void)?
  var onEditToken: (() -> Void)?
  var onApply: ((MediaItem, MetadataCandidate?) throws -> Void)?
  private var task: Task<Void, Never>?
  private var generation = UUID()
  var isPresented: Bool { target != nil }
  var kind: MetadataKind { target?.isLibraryCollection == true ? .series : .movie }
  // query, provider, set token, remove token, restore original, entries, close
  var controlCount: Int { 6 + candidates.count }
  var tokenConfigured: Bool { tmdbToken != nil || tokenStore.isConfigured }
  func present(_ item: MediaItem, search: Bool = true) {
    close()
    target = item
    query = item.title
    provider = item.isLibraryCollection || item.localMetadata?.episode != nil ? .tvmaze : .tmdb
    selection = 0
    if search { self.search() }
  }
  func search() {
    task?.cancel()
    let attempt = UUID()
    generation = attempt
    candidates = []
    loading = true
    message = ""
    selection = 0
    let query = query
    let kind = kind
    let provider = provider
    let token = tmdbToken
    let tokenStore = tokenStore
    let client = client
    task = Task {
      do {
        let credential =
          provider == .tmdb ? (try await Task.detached { try tokenStore.load() }.value) : nil
        let result = try await client.search(
          query: query, kind: kind, provider: provider, token: token ?? credential)
        guard !Task.isCancelled, generation == attempt else { return }
        candidates = result
        message = result.isEmpty ? "没有匹配结果，请修改片名或数据源" : "选择正确的年份与版本"
      } catch {
        guard !Task.isCancelled, generation == attempt else { return }
        message = error.localizedDescription
      }
      if generation == attempt { loading = false }
    }
  }
  func move(_ step: Int) { selection = min(max(0, selection + step), controlCount - 1) }
  func moveVertical(_ step: Int) {
    if step > 0 {
      if selection == 0 { selection = 1 } else if selection <= 4 { selection = 5 } else { move(1) }
    } else {
      if selection <= 4 { selection = 0 } else if selection == 5 { selection = 1 } else { move(-1) }
    }
  }
  func moveHorizontal(_ step: Int) {
    if (1...4).contains(selection) { selection = min(4, max(1, selection + step)) }
  }
  func activate() {
    if selection == 0 {
      onEditQuery?()
      return
    }
    if selection == 1 {
      if kind == .movie {
        message = "电影使用 TMDB，需要先配置自己的访问令牌"
        return
      }
      provider = provider == .tvmaze ? .tmdb : .tvmaze
      search()
      return
    }
    if selection == controlCount - 1 {
      close()
      return
    }
    if selection == 2 {
      onEditToken?()
      return
    }
    if selection == 3 {
      removeToken()
      return
    }
    guard let target else { return }
    do {
      if selection == 4 {
        try onApply?(target, nil)
        close()
        return
      }
      let index = selection - 5
      guard candidates.indices.contains(index) else { return }
      try onApply?(target, candidates[index])
      close()
    } catch { message = error.localizedDescription }
  }
  func saveToken(_ value: String) {
    task?.cancel()
    loading = false
    let attempt = UUID()
    generation = attempt
    let store = tokenStore
    task = Task {
      do {
        try await Task.detached { try store.save(value) }.value
        guard generation == attempt else { return }
        tmdbToken = value.trimmingCharacters(in: .whitespacesAndNewlines)
        message = "访问令牌已保存在这台 Mac"
        if provider == .tmdb { search() }
      } catch { if generation == attempt { message = error.localizedDescription } }
    }
  }
  private func removeToken() {
    task?.cancel()
    loading = false
    let attempt = UUID()
    generation = attempt
    let store = tokenStore
    task = Task {
      do {
        try await Task.detached { try store.remove() }.value
        guard generation == attempt else { return }
        tmdbToken = nil
        message = "已移除 TMDB 访问令牌"
      } catch { if generation == attempt { message = error.localizedDescription } }
    }
  }
  func close() {
    task?.cancel()
    task = nil
    generation = UUID()
    target = nil
    candidates = []
    loading = false
  }
}

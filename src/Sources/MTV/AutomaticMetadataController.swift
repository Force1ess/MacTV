import Foundation
import MTVCore

struct AutomaticMetadataResult: Identifiable {
  let item: MediaItem
  let outcome: String
  let message: String
  var id: String { item.id }
}

@MainActor final class AutomaticMetadataController: ObservableObject {
  @Published var inventoryReport: LibraryInventoryReport?
  @Published private(set) var isPresented = false
  @Published private(set) var phase = "ready"
  @Published private(set) var targets: [AutomaticMetadataTarget] = []
  @Published private(set) var results: [AutomaticMetadataResult] = []
  @Published private(set) var currentTitle = ""
  @Published var selection = 0
  var onMatch: ((MediaItem, MetadataCandidate) throws -> Bool)?
  var onReview: ((MediaItem) -> Void)?
  private var client: any MetadataSearching = MetadataClient()
  private var tokenStore = MetadataTokenStore()
  private var tokenOverride: String?
  private var task: Task<Void, Never>?
  private var generation = UUID()
  var reviewResults: [AutomaticMetadataResult] {
    results.filter { ["review", "credentials", "failed"].contains($0.outcome) }
  }
  var matchedCount: Int { results.filter { $0.outcome == "matched" }.count }
  var controlCount: Int {
    phase == "ready" && !targets.isEmpty ? 2 : (phase == "done" ? 1 + reviewResults.count : 1)
  }
  func prepare(
    targets: [AutomaticMetadataTarget], client: any MetadataSearching,
    tokenStore: MetadataTokenStore, token: String?, inventory: LibraryInventoryReport? = nil
  ) {
    close()
    inventoryReport = inventory
    self.targets = targets
    self.client = client
    self.tokenStore = tokenStore
    tokenOverride = token
    results = []
    currentTitle = ""
    phase = "ready"
    selection = 0
    isPresented = true
  }
  func move(_ step: Int) { selection = min(max(0, selection + step), controlCount - 1) }
  func activate() {
    if phase == "running" {
      cancel()
      return
    }
    if phase == "ready", !targets.isEmpty, selection == 0 {
      start()
      return
    }
    if phase == "done", selection > 0, reviewResults.indices.contains(selection - 1) {
      let item = reviewResults[selection - 1].item
      close()
      onReview?(item)
      return
    }
    close()
  }
  func start() {
    guard phase == "ready" else { return }
    let attempt = UUID()
    generation = attempt
    phase = "running"
    selection = 0
    let targets = targets
    let client = client
    let store = tokenStore
    let provided = tokenOverride
    task = Task {
      var token = provided
      var credentialError: String?
      if token == nil, targets.contains(where: { $0.kind == .movie }) {
        do { token = try await Task.detached { try store.load() }.value } catch {
          credentialError = error.localizedDescription
        }
      }
      for (index, target) in targets.enumerated() {
        guard !Task.isCancelled, generation == attempt else { return }
        currentTitle = target.item.title
        if target.kind == .movie, target.year == nil {
          results.append(
            AutomaticMetadataResult(item: target.item, outcome: "review", message: "电影年份缺失，请确认"))
          continue
        }
        if target.provider == .tmdb, token == nil {
          results.append(
            AutomaticMetadataResult(
              item: target.item, outcome: "credentials", message: credentialError ?? "电影数据源尚未配置访问令牌"
            ))
          continue
        }
        do {
          if index > 0 { try await Task.sleep(for: .milliseconds(550)) }
          let values = try await client.search(
            query: target.item.title, kind: target.kind, provider: target.provider,
            token: target.provider == .tmdb ? token : nil)
          guard !Task.isCancelled, generation == attempt else { return }
          if let candidate = AutomaticMetadata.uniqueMatch(target: target, candidates: values) {
            let saved = try onMatch?(target.item, candidate) == true
            results.append(
              AutomaticMetadataResult(
                item: target.item, outcome: saved ? "matched" : "skipped",
                message: saved ? "片名与年份匹配，已补全" : "已有记录，保持原匹配"))
          } else {
            results.append(
              AutomaticMetadataResult(
                item: target.item, outcome: "review", message: "没有唯一的片名/年份结果，请确认"))
          }
        } catch {
          guard !Task.isCancelled, generation == attempt else { return }
          results.append(
            AutomaticMetadataResult(
              item: target.item, outcome: "failed", message: error.localizedDescription))
          if case MTVError.rateLimited = error { break }
        }
      }
      guard generation == attempt else { return }
      let processed = Set(results.map(\.id))
      for target in targets where !processed.contains(target.id) {
        results.append(
          AutomaticMetadataResult(item: target.item, outcome: "review", message: "服务限流后停止，未处理"))
      }
      phase = "done"
      currentTitle = ""
    }
  }
  func cancel() {
    task?.cancel()
    generation = UUID()
    if phase == "running" {
      let processed = Set(results.map(\.id))
      for target in targets where !processed.contains(target.id) {
        results.append(
          AutomaticMetadataResult(item: target.item, outcome: "review", message: "取消时尚未处理"))
      }
      phase = "done"
      currentTitle = "已取消；已完成的匹配保留"
    }
    selection = 0
  }
  func close() {
    cancel()
    isPresented = false
  }
}

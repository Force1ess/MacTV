import AppKit
import MTVCore

/// In-app maintenance only: no scheduler, no filesystem writes to media, no
/// selection dialogs. Existing index stays visible while a bounded scan runs.
@MainActor final class LibraryMaintenance {
  private var refreshTask: Task<Void, Never>?
  private var enrichmentTask: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []
  private var attempts: [String: Date] = [:]
  private var generation = UUID()
  private var lastScan = Date.distantPast

  func start(model: AppModel) {
    guard !CommandLine.arguments.contains("--ui-smoke") else { return }
    stop()
    refreshTask = Task { [weak self, weak model] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(60)) } catch { return }
        guard let self, let model else { return }
        self.refresh(model: model)
      }
    }
    for name in [NSWorkspace.didMountNotification, NSWorkspace.didWakeNotification, NSWorkspace.didUnmountNotification] {
      observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self, weak model] _ in
        Task { @MainActor in if let model { self?.refresh(model: model) } }
      })
    }
    observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self, weak model] _ in
      Task { @MainActor in if let model { self?.refresh(model: model) } }
    })
  }
  func refresh(model: AppModel) {
    guard !model.mediaRoot.isEmpty, !model.libraryRefreshing, !model.playbackPresented,
      !model.preparingPlayback, !model.needsSMBReconnect,
      Date().timeIntervalSince(lastScan) >= 15 else { return }
    lastScan = Date()
    launchLog.notice("Automatic library refresh requested")
    model.scanLibrary(showFailure: false)
  }
  func sourceChanged() {
    generation = UUID(); enrichmentTask?.cancel(); enrichmentTask = nil
    attempts = [:]; lastScan = .distantPast
  }
  func enrich(model: AppModel) {
    guard !CommandLine.arguments.contains("--ui-smoke"), enrichmentTask == nil else { return }
    attempts = attempts.filter { Date().timeIntervalSince($0.value) < 3600 }
    let source = model.mediaRoot, attempt = generation
    let targets: [AutomaticMetadataTarget]
    do {
      targets = AutomaticMetadata.targets(files: model.libraryFilesForMaintenance, matches: try model.metadataStore.load()).filter {
        Date().timeIntervalSince(attempts[$0.id] ?? .distantPast) >= 3600
      }
    } catch { return }
    guard !targets.isEmpty else { return }
    let client = model.metadata.client, tokenStore = model.metadata.tokenStore
    enrichmentTask = Task { [weak self, weak model] in
      defer { if self?.generation == attempt { self?.enrichmentTask = nil } }
      let token = try? await Task.detached { try tokenStore.load() }.value
      for target in targets {
        guard !Task.isCancelled, let self, let model, self.generation == attempt,
          model.mediaRoot == source else { return }
        // Do not compete with playback for bandwidth or disk access. Next scan
        // will continue the unfinished batch without showing a modal sheet.
        guard !model.playbackPresented else { return }
        self.attempts[target.id] = Date()
        if target.kind == .movie, target.year == nil || token == nil { continue }
        do {
          let candidates = try await client.search(query: target.item.title, kind: target.kind,
            provider: target.provider, token: target.provider == .tmdb ? token : nil)
          guard !Task.isCancelled, self.generation == attempt, model.mediaRoot == source else { return }
          if let match = AutomaticMetadata.uniqueMatch(target: target, candidates: candidates) {
            _ = try model.automaticMetadata.onMatch?(target.item, match)
          }
        } catch {
          launchLog.notice("Background poster lookup failed; retry deferred")
          if case MTVError.rateLimited = error { break }
        }
        do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
      }
    }
  }
  func stop() {
    refreshTask?.cancel(); refreshTask = nil
    sourceChanged()
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
    observers = []
  }
}

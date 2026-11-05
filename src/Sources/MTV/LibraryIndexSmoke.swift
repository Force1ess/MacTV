import AppKit
import MTVCore

extension UISmoke {
  static func libraryIndexSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String:
    Bool]
  {
    let source = model.captureLibrarySource()
    let index = model.libraryIndex
    let matches = model.metadataStore
    let root = output.appendingPathComponent("IndexLibrary")
    let offline = output.appendingPathComponent("IndexLibraryOffline")
    defer {
      if FileManager.default.fileExists(atPath: offline.path) {
        try? FileManager.default.moveItem(at: offline, to: root)
      }
      model.notice = nil
      model.detail = nil
      model.libraryIndex = index
      model.metadataStore = matches
      model.restoreLibrarySource(source)
      model.navigate(.home)
    }
    var checks: [String: Bool] = [:]
    func waitForScan() async {
      for _ in 0..<300 {
        if !model.libraryRefreshing { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/MTV/Fixtures/PlaybackFixture.mp4")
      for name in ["Test.Movie.2024.mp4", "Example.Show.S01E01.mp4"] {
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent(name))
      }
      let file = output.appendingPathComponent("index-fixture/index.json")
      model.libraryIndex = LibraryIndexStore(file: file)
      model.metadataStore = MetadataStore(
        file: output.appendingPathComponent("index-fixture/matches.json"))
      model.useLocalRoot(root)
      await waitForScan()
      let snapshot = try await LibraryIndexStore(file: file).load(root: root)
      checks["indexCompleteScanPersisted"] =
        snapshot?.items.count == 2 && model.libraryIndexedAt != nil
      if let series = model.visibleItems.firstIndex(where: { $0.kind == .series }) {
        model.focus.select(row: 2 + series / 6, column: series % 6)
        model.handle(.select)
        if let episode = model.visibleItems.first { model.selectContent(episode) }
      }
      let path = model.libraryPath.map(\.id)
      let detail = model.detail?.id
      model.scanLibrary()
      await waitForScan()
      checks["indexRefreshPreservesOpenEpisodeAndHierarchy"] =
        path.count == 1
        && model.libraryPath.map(\.id) == path && model.detail?.id == detail && detail != nil
      model.loading = true
      model.scanLibrary()
      await waitForScan()
      checks["indexRefreshDoesNotClearForegroundLoad"] = model.loading && !model.libraryRefreshing
      model.loading = false
      model.detail = nil
      if let movie = snapshot?.items.first(where: { $0.localMetadata?.episode == nil }) {
        _ = try model.metadataStore.set(
          targetID: movie.id,
          candidate: MetadataCandidate(
            provider: .tmdb, externalID: 701, kind: .movie, title: "User corrected title",
            year: 2024))
      }
      try FileManager.default.moveItem(at: root, to: offline)
      model.applyLibraryItems([])
      model.restoreLibraryFromIndex()
      await waitForScan()
      checks["indexOfflineColdRestoreKeepsMedia"] =
        model.library.count == 2 && model.libraryNeedsAttention
        && model.libraryIndexedAt != nil && !model.libraryRefreshing && model.notice == nil
      checks["indexRestoreReappliesSeparateManualMatches"] = model.library.contains {
        $0.title == "User corrected title"
      }
      let retained = try await LibraryIndexStore(file: file).load(root: root)
      checks["indexFailureDoesNotOverwriteRawSnapshot"] =
        retained?.items.count == 2
        && retained?.items.contains(where: { $0.title == "Test Movie" }) == true
      model.navigate(.library)
      await settle()
      capture(window, to: output.appendingPathComponent("25-offline-index.png"))
      try FileManager.default.moveItem(at: offline, to: root)
      let unavailableLink = root.appendingPathComponent("Offline.Linked.Movie.2023.mp4")
      try FileManager.default.createSymbolicLink(at: unavailableLink,
        withDestinationURL: output.appendingPathComponent("UnavailableVolume/Film.mp4"))
      model.scanLibrary()
      await waitForScan()
      let afterUnavailable = try await LibraryIndexStore(file: file).load(root: root)
      checks["indexUnavailableLinkedMediaRetainedWithOfflineStatus"] = model.library.count == 3
        && model.libraryNeedsAttention && afterUnavailable?.items.count == 3
        && afterUnavailable?.items.filter({ $0.localMetadata?.sourceReachable == false }).count == 1
      await settle()
      capture(window, to: output.appendingPathComponent("26-offline-linked-item.png"))
      try FileManager.default.removeItem(at: unavailableLink)
      for number in 0..<999 {
        try Data().write(to: root.appendingPathComponent("Overflow.\(number).mp4"))
      }
      model.scanLibrary(limit: 1000)
      await waitForScan()
      let afterLimit = try await LibraryIndexStore(file: file).load(root: root)
      checks["indexTruncatedScanPreservesPreviousSnapshot"] = model.library.count == 3
        && model.libraryNeedsAttention && afterLimit?.items.count == 3
      model.scanLibrary()
      await waitForScan()
      let larger = try await LibraryIndexStore(file: file).load(root: root)
      checks["indexDefaultScanHandlesMoreThanOneThousandFiles"] = model.library.count == 1001
        && !model.libraryNeedsAttention && larger?.items.count == 1001
      for number in 0..<999 {
        try FileManager.default.removeItem(at: root.appendingPathComponent("Overflow.\(number).mp4"))
      }
      for name in ["Test.Movie.2024.mp4", "Example.Show.S01E01.mp4"] {
        try FileManager.default.removeItem(at: root.appendingPathComponent(name))
      }
      model.scanLibrary()
      await waitForScan()
      let empty = try await LibraryIndexStore(file: file).load(root: root)
      checks["indexVerifiedEmptyDirectoryCanReplaceSnapshot"] =
        model.library.isEmpty
        && !model.libraryNeedsAttention && empty?.items.isEmpty == true
    } catch { checks["indexFixtureFlow"] = false }
    return checks
  }
}

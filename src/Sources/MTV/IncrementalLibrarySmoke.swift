import AppKit
import MTVCore

extension UISmoke {
  static func incrementalLibrarySmoke(model: AppModel, output: URL) async -> [String: Bool] {
    await model.waitForSourceSave()
    let original = model.captureLibrarySource()
    let oldSource = model.sourceStore, oldSources = model.savedSources.store, oldIndex = model.libraryIndex
    defer {
      model.sourceStore = oldSource; model.savedSources.store = oldSources; model.libraryIndex = oldIndex
      model.notice = nil; model.restoreLibrarySource(original); model.navigate(.home)
    }
    let root = output.appendingPathComponent("incremental-owned"), media = root.appendingPathComponent("films")
    let indexFile = root.appendingPathComponent("index.json")
    var checks: [String: Bool] = [:]
    var diagnostics: [String: Any] = ["generatedFixtures": true, "physicalNASVerified": false]
    func ready() async {
      for _ in 0..<400 { if !model.libraryRefreshing { return }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    do {
      try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/PlaybackFixture.mp4")
      for name in ["A", "B"] {
        try FileManager.default.copyItem(at: fixture, to: media.appendingPathComponent(name + ".mp4"))
        try Data("<movie><title>\(name) 影片</title></movie>".utf8).write(to: media.appendingPathComponent(name + ".nfo"))
      }
      model.sourceStore = LibrarySourceStore(file: root.appendingPathComponent("selected.json"))
      model.savedSources.store = SavedLibrarySourcesStore(file: root.appendingPathComponent("sources.json"))
      model.libraryIndex = LibraryIndexStore(file: indexFile)
      model.useLocalRoot(media)
      await ready(); await model.waitForSourceSave()
      checks["incrementalInitialScanReadsSidecars"] = model.library.count == 2 && model.libraryReusedCount == 0 && model.libraryNFOReadCount == 2
      let started = Date()
      model.scanLibrary(); await ready()
      diagnostics["warmScanWallSeconds"] = Date().timeIntervalSince(started)
      diagnostics["warmReused"] = model.libraryReusedCount; diagnostics["warmNFOReads"] = model.libraryNFOReadCount
      checks["incrementalWarmRefreshReusesWithoutNFOReads"] = model.libraryReusedCount == 2 && model.libraryNFOReadCount == 0
      try Data("<movie><title>更新影片</title></movie>".utf8).write(to: media.appendingPathComponent("A.nfo"))
      model.scanLibrary(); await ready()
      checks["incrementalChangedSidecarOnlyReparsesAffectedItem"] = model.libraryReusedCount == 1 && model.libraryNFOReadCount == 1 && model.library.contains { $0.title == "更新影片" }
      await openSettingWithRemote(.scan, model: model); await ready()
      checks["incrementalRemoteFullRecognitionBypassesReuse"] = model.libraryReusedCount == 0 && model.libraryNFOReadCount == 2
      model.libraryIndex = LibraryIndexStore(file: indexFile)
      model.useLocalRoot(media); await ready(); await model.waitForSourceSave()
      checks["incrementalSourceReloadRestoresPersistedReuse"] = model.libraryReusedCount == 2 && model.libraryNFOReadCount == 0 && model.library.contains { $0.title == "更新影片" }
      let before = try Data(contentsOf: indexFile)
      model.scanLibrary(limit: 1); await ready()
      let afterLimited = try Data(contentsOf: indexFile)
      checks["incrementalTruncatedScanPreservesPreviousIndex"] = model.library.count == 2 && afterLimited == before
      model.scanLibrary(); await ready()
      checks["incrementalTruncatedStateDoesNotPoisonNextRefresh"] = model.libraryReusedCount == 2 && model.libraryNFOReadCount == 0
      let current = try Data(contentsOf: indexFile)
      try FileManager.default.moveItem(at: media, to: root.appendingPathComponent("away"))
      model.scanLibrary(showFailure: false); await ready()
      let afterUnavailable = try Data(contentsOf: indexFile)
      checks["incrementalUnavailableSourcePreservesDescriptionsAndIndex"] = model.library.count == 2 && afterUnavailable == current && model.libraryNeedsAttention
    } catch { checks["incrementalFixtureSetup"] = false; diagnostics["error"] = error.localizedDescription }
    if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("incremental-diagnostics.json"))
    }
    return checks
  }
}

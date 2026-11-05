import AVFoundation
import AppKit
import MTVCore

extension UISmoke {
  static func metadataFailureSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    await model.waitForSourceSave()
    let original = model.captureLibrarySource()
    let oldSource = model.sourceStore, oldSources = model.savedSources.store, oldIndex = model.libraryIndex, oldEngine = model.preferredEngine
    defer {
      model.stopPlayback(); model.preferredEngine = oldEngine
      model.sourceStore = oldSource; model.savedSources.store = oldSources; model.libraryIndex = oldIndex
      model.notice = nil; model.restoreLibrarySource(original); model.navigate(.home)
    }
    let root = output.appendingPathComponent("metadata-failure-owned"), media = root.appendingPathComponent("films")
    let indexFile = root.appendingPathComponent("index.json")
    var checks: [String: Bool] = [:]
    func ready() async {
      for _ in 0..<300 { if !model.libraryRefreshing { return }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    func nfo(_ name: String, _ title: String) throws {
      try Data("<movie><title>\(title)</title></movie>".utf8).write(to: media.appendingPathComponent(name + ".nfo"))
    }
    do {
      try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/PlaybackFixture.mp4")
      for name in ["A", "B"] { try FileManager.default.copyItem(at: fixture, to: media.appendingPathComponent(name + ".mp4")); try nfo(name, "原有影片 " + name) }
      model.sourceStore = LibrarySourceStore(file: root.appendingPathComponent("selected.json"))
      model.savedSources.store = SavedLibrarySourcesStore(file: root.appendingPathComponent("sources.json"))
      model.libraryIndex = LibraryIndexStore(file: indexFile); model.preferredEngine = .system
      model.useLocalRoot(media); await ready(); await model.waitForSourceSave()
      try Data("<movie><title>broken".utf8).write(to: media.appendingPathComponent("A.nfo"))
      try nfo("B", "新识别影片 B")
      model.scanLibrary(); await ready()
      checks["metadataFailureKeepsAffectedTitleAndUpdatesOtherItem"] = model.library.contains { $0.title == "原有影片 A" } && model.library.contains { $0.title == "新识别影片 B" }
      checks["metadataFailureVisibleInStatusAndItem"] = model.libraryMetadataFailureCount == 1 && model.libraryNeedsAttention
        && model.libraryStatus.hasSuffix(L("；\(1) 项资料读取失败，其中 \(1) 项沿用缓存")) && model.library.first { $0.title == "原有影片 A" }?.localMetadata?.metadataReadFailed == true
      model.navigate(.library)
      await settle(); capture(window, to: output.appendingPathComponent("metadata-warning-library.png"))
      if let item = model.library.first(where: { $0.title == "原有影片 A" }) { model.selectContent(item) }
      await settle(); capture(window, to: output.appendingPathComponent("metadata-warning-detail.png"))
      let cold = try await LibraryIndexStore(file: indexFile).load(root: media)
      checks["metadataFailurePersistsInColdIndex"] = cold?.items.first { $0.title == "原有影片 A" }?.localMetadata?.metadataReadFailed == true
      await openSettingWithRemote(.scan, model: model); await ready()
      checks["metadataFailureFullReidentifyRetainsCache"] = model.libraryReusedCount == 0 && model.libraryMetadataFailureCount == 1 && model.library.contains { $0.title == "原有影片 A" }
      model.libraryIndex = LibraryIndexStore(file: indexFile); model.useLocalRoot(media); await ready(); await model.waitForSourceSave()
      checks["metadataFailureSourceReloadKeepsTitle"] = model.library.contains { $0.title == "原有影片 A" && $0.localMetadata?.metadataReadFailed == true }
      try nfo("A", "修复后的影片 A")
      model.scanLibrary(); await ready()
      checks["metadataFailureRepairClearsWarning"] = model.libraryMetadataFailureCount == 0 && !model.libraryNeedsAttention
        && model.library.contains { $0.title == "修复后的影片 A" && $0.localMetadata?.metadataReadFailed != true }
      try FileManager.default.removeItem(at: media.appendingPathComponent("A.nfo"))
      model.scanLibrary(); await ready()
      checks["metadataFailureIntentionalRemovalUsesFilename"] = model.libraryMetadataFailureCount == 0 && model.library.contains { $0.title == "A" && $0.localMetadata?.metadataReadFailed != true }
      try FileManager.default.copyItem(at: fixture, to: media.appendingPathComponent("C.mp4"))
      try Data("<movie>broken".utf8).write(to: media.appendingPathComponent("C.nfo"))
      model.scanLibrary(); await ready()
      let newItem = model.library.first { $0.title == "C" }
      checks["metadataFailureNewItemHasWarningWithoutOldCache"] = newItem?.localMetadata?.metadataReadFailed == true && model.libraryMetadataFailureCount == 1
      if let newItem { model.selectContent(newItem); model.handle(.select) }
      var decoded = false
      for _ in 0..<200 {
        if model.player?.currentItem?.status == .readyToPlay, model.testDecodedFrame() != nil { decoded = true; break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      checks["metadataFailureDoesNotBlockVideoDecode"] = decoded && model.playbackTitle == "C"
      model.stopPlayback(); await model.waitForSourceSave()
    } catch { checks["metadataFailureFixtureSetup"] = false }
    return checks
  }
}

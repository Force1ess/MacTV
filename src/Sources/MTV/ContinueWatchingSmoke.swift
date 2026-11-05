import AppKit
import MTVCore
import Vision

extension UISmoke {
  static func continueWatchingSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    let args = CommandLine.arguments
    let scope = args.firstIndex(of: "--history-test-scope").flatMap { $0 + 1 < args.count ? UUID(uuidString: args[$0 + 1]) : nil }
    let root = scope.map { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/TestResults/ContinueWatchingStartup-" + $0.uuidString.lowercased()) }
      ?? output.appendingPathComponent("continue-watching-owned")
    let previous = model.captureLibrarySource(), oldSource = model.sourceStore, oldSaved = model.savedSources.store, oldIndex = model.libraryIndex
    let oldEngine = model.preferredEngine
    defer { model.stopPlayback(); model.sourceStore = oldSource; model.savedSources.store = oldSaved; model.libraryIndex = oldIndex
      model.preferredEngine = oldEngine; model.continueWatching.menuID = nil; model.notice = nil; model.detail = nil; model.restoreLibrarySource(previous); model.navigate(.home) }
    var checks: [String: Bool] = [:]
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<300 { if condition() { return }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    func selectHistory(_ id: String) {
      if let index = model.continueWatching.entries.firstIndex(where: { $0.context.mediaID == id }) {
        model.focus.select(row: 3, column: index); model.handle(.select)
      }
    }
    func shelfVisible() -> Bool {
      guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      guard let image = bitmap.cgImage else { return false }
      let request = VNRecognizeTextRequest(); request.recognitionLanguages = ["zh-Hans", "en-US"]
      request.recognitionLevel = .accurate
      do { try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined().replacingOccurrences(of: " ", with: "").contains("继续观看")
      } catch { return false }
    }
    do {
      await wait { !model.loading }; model.stopPlayback()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      model.sourceStore = LibrarySourceStore(file: root.appendingPathComponent("selection.json"))
      model.savedSources.store = SavedLibrarySourcesStore(file: root.appendingPathComponent("sources.json"))
      model.libraryIndex = LibraryIndexStore(file: root.appendingPathComponent("index.json"))
      model.preferredEngine = .system
      let a = root.appendingPathComponent("Library A"), b = root.appendingPathComponent("Library B")
      if args.contains("--history-cold-read") {
        model.continueWatching.reload()
        checks["historyColdProcessRestoresTwoRoutes"] = model.continueWatching.entries.count == 2
          && Set(model.continueWatching.entries.compactMap { $0.context.librarySource?.path }) == Set([a.path, b.path])
        model.useLocalRoot(b); await wait { !model.libraryRefreshing }; await model.waitForSourceSave(); model.navigate(.home)
        let id = a.appendingPathComponent("Night.Movie.2024.mp4").path
        selectHistory(id); await wait { model.detail?.id == id || model.notice != nil }
        checks["historyColdProcessOpensArchivedOtherSource"] = model.detail?.id == id && model.mediaRoot == a.path && model.historyReturnEntryID != nil
        if let detail = model.detail {
          let resumeAt = model.resumeStore.position(for: detail.id)
          model.handle(.select); await wait { model.testDecodedFrame() != nil && (model.player?.currentTime().seconds ?? 0) > resumeAt + 0.25 }
          checks["historyColdProcessActuallyContinuesVideo"] = model.playbackTitle == detail.title && model.testDecodedFrame() != nil && (model.player?.currentTime().seconds ?? 0) > resumeAt + 0.25 }
        return checks
      }
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/IndependentLongGOP45-v1.mp4")
      for directory in [a, b] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let film = directory.appendingPathComponent("Night.Movie.2024.mp4")
        if !FileManager.default.fileExists(atPath: film.path) { try FileManager.default.copyItem(at: fixture, to: film) }
        let artwork = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/GeneratedPoster.png")
        let poster = directory.appendingPathComponent("poster.jpg")
        if !FileManager.default.fileExists(atPath: poster.path), let image = NSImage(contentsOf: artwork),
          let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
          let jpeg = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.95]) { try jpeg.write(to: poster) }
      }
      var ids: [String] = []
      for directory in [a, b] {
        model.useLocalRoot(directory); await wait { !model.libraryRefreshing }; await model.waitForSourceSave()
        guard let item = model.library.first else { throw MTVError.message("生成片源未进入资料库") }
        ids.append(item.id)
        model.resumeStore.save(12, for: item.id, duration: 45)
        model.selectContent(item); model.handle(.select)
        await wait { model.testDecodedFrame() != nil && (model.player?.currentTime().seconds ?? 0) > 12.25 || model.notice != nil }
        checks["historyRealPlaybackRecorded-" + directory.lastPathComponent] = model.testDecodedFrame() != nil && (model.player?.currentTime().seconds ?? 0) > 12.25
        model.stopPlayback(); model.detail = nil
      }
      model.navigate(.home)
      checks["historyTwoLibrariesProduceOneHorizontalRow"] = model.continueWatching.entries.count == 2
        && model.homeMediaOffset == 4 && model.focus.rows[3] == 2
        && model.continueWatching.entries.first?.context.mediaID == ids[1]
      checks["historyLibraryCardsKeepTheirArtwork"] = model.continueWatching.entries.allSatisfy { model.historyPoster($0) != nil }
      model.focus.select(row: 3, column: 1); await settle(); capture(window, to: output.appendingPathComponent("continue-watching-home.png"))
      checks["historyFocusedRowIsActuallyVisible"] = shelfVisible()
      model.handle(.select); await wait { model.detail?.id == ids[0] || model.notice != nil }
      checks["historyRemoteOpensDifferentSourceWithoutGuessingURL"] = model.mediaRoot == a.path && model.detail?.id == ids[0] && model.historyReturnEntryID != nil
      model.handle(.back)
      checks["historyBackRestoresHomeRowAndCard"] = model.section == .home && model.focus.row == 3 && model.focus.column == 1
      await settle(); checks["historyBackRestoresVisibleRow"] = shelfVisible()
      model.handle(.menu)
      checks["historyRemoteMenuOpens"] = model.continueWatching.menuID != nil
      model.handle(.right); model.handle(.select)
      checks["historyRemovePreservesPlaybackPosition"] = model.continueWatching.entries.count == 1 && model.resumeStore.position(for: ids[0]) > 12
      model.navigate(.library)
      guard let item = model.library.first(where: { $0.id == ids[0] }) else { throw MTVError.message("已打开来源丢失测试片") }
      let resumeAt = model.resumeStore.position(for: item.id)
      model.selectContent(item); model.handle(.select)
      await wait { model.testDecodedFrame() != nil && (model.player?.currentTime().seconds ?? 0) > resumeAt + 0.25 }
      model.stopPlayback(); model.detail = nil; model.navigate(.home)
      checks["historyWatchingAgainReturnsRemovedCard"] = model.continueWatching.entries.count == 2 && model.continueWatching.entries.first?.context.mediaID == ids[0]
      if args.contains("--history-cold-write") { checks["historyWriterKeepsTwoRecordsForNextProcess"] = model.continueWatching.entries.count == 2; return checks }
      let missing = try PlaybackHistoryContext(mediaID: "missing", sourceID: "removed.plugin", title: "已移除模块测试", sourceTitle: "模块", reference: "opaque")
      model.resumeStore.save(12, for: missing.mediaID, source: missing.sourceID, duration: 100); try model.resumeStore.remember(missing); model.continueWatching.reload()
      selectHistory("missing"); await wait { model.notice != nil }
      checks["historyMissingModuleFailsWithoutLocalPlayback"] = model.notice != nil && !model.playbackPresented && !model.preparingPlayback && model.section == .home
      model.notice = nil; model.continueWatching.remove(missing.id)
      guard let removed = try await model.savedSources.store.load().first(where: { $0.path == b.path }) else { throw MTVError.message("测试来源未保存") }
      _ = try await model.savedSources.store.remove(removed.id)
      selectHistory(ids[1]); await wait { model.notice != nil }
      checks["historyRemovedSourceDoesNotSilentlyReAdd"] = model.notice != nil && model.mediaRoot == a.path && model.section == .home
      model.notice = nil
      for entry in model.continueWatching.entries { model.continueWatching.remove(entry.id) }
      checks["historyLastRemovalRestoresOriginalGridOffset"] = model.homeMediaOffset == 3 && model.continueWatching.entries.isEmpty
    } catch { checks["historyOwnedFixtureSetup"] = false }
    return checks
  }
}

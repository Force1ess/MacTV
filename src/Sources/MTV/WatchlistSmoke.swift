import AVFoundation
import AppKit
import MTVCore
import Vision

extension UISmoke {
  static func watchlistSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--history-test-scope"), index + 1 < args.count,
      let scope = UUID(uuidString: args[index + 1]) else { return ["watchlistExplicitPrivateScopeRequired": false] }
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/TestResults/WatchlistStartup-" + scope.uuidString.lowercased())
    let previous = model.captureLibrarySource(), oldSource = model.sourceStore, oldSaved = model.savedSources.store, oldIndex = model.libraryIndex, oldEngine = model.preferredEngine
    var checks: [String: Bool] = [:]
    defer {
      model.stopPlayback(); model.watchlist.cancelEnrichment(); model.watchlist.menuID = nil
      model.sourceStore = oldSource; model.savedSources.store = oldSaved; model.libraryIndex = oldIndex; model.preferredEngine = oldEngine
      model.notice = nil; model.detail = nil; model.restoreLibrarySource(previous); model.navigate(.home)
    }
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<600 { if condition() { return }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    func openFavorite(_ id: String) {
      model.navigate(.home)
      if let index = model.watchlist.entries.firstIndex(where: { $0.mediaID == id }) {
        model.focus.select(row: model.watchlistRow, column: index); model.handle(.select)
      }
    }
    func addByRemote(_ item: MediaItem) {
      model.selectContent(item)
      guard let index = model.detailControls(for: item).firstIndex(of: .watchlist) else { return }
      for _ in 0..<index { model.handle(.right) }; model.handle(.select)
    }
    func visibleText(_ expected: String) -> Bool {
      guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      guard let image = bitmap.cgImage else { return false }
      let request = VNRecognizeTextRequest(); request.recognitionLanguages = ["zh-Hans", "en-US"]; request.recognitionLevel = .accurate
      do { try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined().replacingOccurrences(of: " ", with: "").contains(expected)
      } catch { return false }
    }
    func shelfVisible() -> Bool { visibleText("待看片单") }
    do {
      await wait { !model.loading && !model.libraryRefreshing }; model.stopPlayback()
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      model.sourceStore = LibrarySourceStore(file: root.appendingPathComponent("selection.json"))
      model.savedSources.store = SavedLibrarySourcesStore(file: root.appendingPathComponent("sources.json"))
      model.libraryIndex = LibraryIndexStore(file: root.appendingPathComponent("index.json")); model.preferredEngine = .system
      let a = root.appendingPathComponent("Library A"), b = root.appendingPathComponent("Library B")
      let idA = a.appendingPathComponent("Night.Movie.2024.mp4").path
      if args.contains("--watchlist-cold-read") {
        model.watchlist.reload()
        checks["watchlistColdProcessRestoresTwoUnplayedEntries"] = model.watchlist.entries.count == 2 && model.resumeStore.position(for: idA) == 0
        model.useLocalRoot(b); await wait { !model.libraryRefreshing }; await model.waitForSourceSave()
        openFavorite(idA); await wait { model.detail?.id == idA || model.notice != nil }
        checks["watchlistColdProcessReopensOtherSavedLibrary"] = model.detail?.id == idA && model.mediaRoot == a.path && model.savedContentReturn?.shelf == .watchlist
        model.handle(.select); await wait { model.testDecodedFrame() != nil && (model.player?.currentTime().seconds ?? 0) > 2 }
        checks["watchlistColdProcessActuallyDecodesOriginalMedia"] = model.testDecodedFrame() != nil && (model.player?.currentTime().seconds ?? 0) > 2
        return checks
      }
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/IndependentLongGOP45-v1.mp4")
      let poster = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/GeneratedPoster.png")
      var items: [MediaItem] = []
      for directory in [a, b] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let film = directory.appendingPathComponent("Night.Movie.2024.mp4")
        if !FileManager.default.fileExists(atPath: film.path) { try FileManager.default.copyItem(at: fixture, to: film) }
        let cover = directory.appendingPathComponent("poster.png")
        if !FileManager.default.fileExists(atPath: cover.path) { try FileManager.default.copyItem(at: poster, to: cover) }
        let name = directory == a ? "云端列车" : "深海旅人"
        try Data("<movie><title>\(name)</title><year>2024</year><plot>独立生成的客厅界面测试片源。</plot></movie>".utf8).write(to: directory.appendingPathComponent("Night.Movie.2024.nfo"))
        model.useLocalRoot(directory); await wait { !model.libraryRefreshing }; await model.waitForSourceSave()
        guard let item = model.library.first else { throw MTVError.message("自有片源未扫描") }
        items.append(item); addByRemote(item)
        checks["watchlistRemoteDetailAddsWithoutPlayback-" + directory.lastPathComponent] = model.watchlist.contains(item) && !model.playbackPresented && model.resumeStore.position(for: item.id) == 0
        model.handle(.back)
      }
      checks["watchlistUnplayedFavoritesAreIndependentOfHistory"] = model.watchlist.entries.count == 2 && model.continueWatching.entries.isEmpty
      if args.contains("--watchlist-cold-write") { return checks }
      openFavorite(idA); await wait { model.detail?.id == idA || model.notice != nil }
      checks["watchlistRemoteOpensDifferentSource"] = model.detail?.id == idA && model.mediaRoot == a.path && model.savedContentReturn?.shelf == .watchlist
      model.handle(.back); await settle()
      checks["watchlistDetailBackRestoresCardAndVisibleShelf"] = model.section == .home && model.focus.row == model.watchlistRow
        && model.watchlist.entries.indices.contains(model.focus.column) && model.watchlist.entries[model.focus.column].mediaID == idA && shelfVisible()
      capture(window, to: output.appendingPathComponent("watchlist-unplayed.png"))
      openFavorite(idA); await wait { model.detail?.id == idA }; model.handle(.select)
      await wait { model.testDecodedFrame() != nil && (model.player?.currentTime().seconds ?? 0) > 6.1 }
      checks["watchlistSavedLocalCardActuallyPlays"] = model.testDecodedFrame() != nil && (model.player?.currentTime().seconds ?? 0) > 6.1
      model.stopPlayback(); model.handle(.back); await settle()
      checks["watchlistAndHistoryCoexistAfterRealPlayback"] = model.continueWatching.entries.contains { $0.context.mediaID == idA }
        && model.watchlist.entries.contains { $0.mediaID == idA } && model.watchlistRow == 4 && model.focus.row == 4 && shelfVisible()
      capture(window, to: output.appendingPathComponent("watchlist-and-history.png"))
      if let gridItem = model.visibleItems.first {
        model.focus.select(row: model.homeMediaOffset, column: 0); model.handle(.select)
        checks["watchlistInsertedShelvesKeepLibraryGridSelectionCorrect"] = model.detail?.id == gridItem.id && model.detail?.source == "local"
        model.handle(.back)
      } else { checks["watchlistInsertedShelvesKeepLibraryGridSelectionCorrect"] = false }
      if let index = model.watchlist.entries.firstIndex(where: { $0.mediaID == idA }) { model.focus.select(row: model.watchlistRow, column: index) }
      model.handle(.menu); model.handle(.right); model.handle(.select)
      checks["watchlistRemoteMenuRemovalPreservesHistoryAndProgress"] = !model.watchlist.entries.contains { $0.mediaID == idA }
        && model.continueWatching.entries.contains { $0.context.mediaID == idA } && model.resumeStore.position(for: idA) > 6
      if let example = model.plugins.first(where: { $0.id == "mtv.example" }) {
        model.openModule(example); await wait { !model.loading }
        guard let item = model.online.first else { throw MTVError.message("示例模块缺少内容") }
        addByRemote(item); model.handle(.back); openFavorite(item.id)
        await wait { model.detail?.source == example.id || model.notice != nil }
        checks["watchlistModuleReopensStablePartAndCollection"] = model.detail?.reference == (item.reference ?? item.id) && model.detail?.collectionReference == item.collectionReference && model.canOpenCollection(model.detail ?? item)
        await settle()
        checks["watchlistSavedModuleDoesNotLoadUnrelatedRootFeed"] = !model.loading && model.online.isEmpty && PluginClient.runningProcessIDs(pluginID: example.id).isEmpty
        if let index = model.detailControls(for: item).firstIndex(of: .collection) {
          model.detailAction = 0
          for _ in 0..<index { model.handle(.right) }; model.handle(.select)
          await wait { !model.loading }
          checks["watchlistSavedDetailRemoteOpensCollection"] = model.detail == nil && model.modulePath.count == 1 && model.online.count == 2
          model.handle(.back)
          checks["watchlistCollectionBackRestoresSavedDetailAndReturnRoute"] = model.detail?.id == item.id && model.savedContentReturn?.shelf == .watchlist
            && model.detailControls(for: item)[model.detailAction] == .collection
        } else { checks["watchlistSavedDetailRemoteOpensCollection"] = false }
        model.handle(.back)
        let all = model.plugins; model.plugins.removeAll { $0.id == example.id }
        openFavorite(item.id); await wait { model.notice != nil }
        checks["watchlistRemovedModuleCannotFallBackToLocalPlayback"] = model.notice != nil && !model.preparingPlayback && !model.playbackPresented && model.detail == nil
        model.notice = nil; model.plugins = all
      } else { checks["watchlistExampleAvailable"] = false }
      let bID = items[1].id
      openFavorite(bID); await wait { model.detail?.id == bID }; model.handle(.back)
      let count = model.watchlist.entries.count
      if let preceding = model.watchlist.entries.first(where: { $0.mediaID != bID }) {
        model.watchlist.remove(preceding.id)
        checks["watchlistRemovingPrecedingCardKeepsSelectedIdentity"] = model.focus.row == model.watchlistRow
          && model.watchlist.entries.indices.contains(model.focus.column) && model.watchlist.entries[model.focus.column].mediaID == bID
      }
      for context in model.watchlist.entries { model.watchlist.remove(context.id) }
      checks["watchlistLastRemovalKeepsHomeFocusValid"] = count > 0 && model.watchlist.entries.isEmpty
        && model.focus.row < model.focus.rows.count && model.homeMediaOffset == 4 && model.continueWatching.entries.count == 1
      // A late cached NAS-image lookup must not recreate a removed favorite.
      let context = try watchlistRequireContext(model.savedContext(for: items[1], capability: "watchlist"))
      var started = false
      try model.watchlist.add(context) { started = true; try? await Task.sleep(for: .milliseconds(150)); return "https://images.example.test/cover.jpg" }
      await wait { started }
      model.watchlist.remove(context.id); try? await Task.sleep(for: .milliseconds(250))
      checks["watchlistCancelledArtworkLookupCannotReinsertRemovedEntry"] = started && !model.watchlist.entries.contains { $0.id == context.id }
      started = false
      try model.watchlist.add(context) { started = true; try? await Task.sleep(for: .milliseconds(150)); return "https://images.example.test/cover.jpg" }
      await wait { started }
      let changed = try PlaybackHistoryContext(mediaID: context.mediaID, sourceID: context.sourceID, title: "人工更新后的名称", sourceTitle: context.sourceTitle, librarySource: context.librarySource)
      try model.resumeStore.addToWatchlist(changed); model.watchlist.reload(); try? await Task.sleep(for: .milliseconds(250))
      checks["watchlistLateArtworkCannotOverwriteNewMetadata"] = model.watchlist.entries.first?.title == changed.title && model.watchlist.entries.first?.poster == nil
      model.watchlist.remove(context.id)
      let lastTitle = "最远片单卡片"
      for index in 0..<10 {
        let sample = try PlaybackHistoryContext(mediaID: "focus-\(index)", sourceID: "mtv.example", title: index == 0 ? lastTitle : "横向导航样例\(index)", sourceTitle: "无媒体的界面示例", reference: "demo")
        try model.watchlist.add(sample)
      }
      model.navigate(.home); model.focus.select(row: model.watchlistRow, column: 0); await settle()
      let initiallyHidden = !visibleText(lastTitle)
      for _ in 1..<model.watchlist.entries.count { model.handle(.right) }
      await settle()
      checks["watchlistRemoteScrollsOffscreenCardIntoActualViewport"] = initiallyHidden && model.focus.column == 9 && visibleText(lastTitle)
      capture(window, to: output.appendingPathComponent("watchlist-horizontal-last-card.png"))
      for value in model.watchlist.entries { model.watchlist.remove(value.id) }
      if args.contains("--live-services") {
        guard let bili = model.plugins.first(where: { $0.id == "mtv.bilibili" }) else { throw MTVError.message("缺少Bilibili模块") }
        model.openModule(bili); await wait { !model.loading }
        model.lookupModule("https://www.bilibili.com/video/BV1wD4y1o7AS/?p=2", owner: bili.id)
        await wait { model.detail != nil || model.moduleLoadFailure != nil }
        guard let part = model.detail else { throw MTVError.message("真实分P查找未返回详情") }
        addByRemote(part); model.handle(.back); openFavorite(part.id)
        await wait { model.detail?.reference == "BV1wD4y1o7AS:1298431128" }
        checks["watchlistRealBilibiliReopensPartAndCollectionWithoutMediaURL"] = model.detail?.reference == "BV1wD4y1o7AS:1298431128"
          && model.detail?.collectionReference == "BV1wD4y1o7AS" && model.detail?.url == nil
        await settle(); capture(window, to: output.appendingPathComponent("watchlist-real-part.png"))
        model.handle(.select)
        var frame = false, audio: PlaybackAudioProbe?
        for _ in 0..<450 {
          if model.notice != nil || model.playbackInterruption != nil { break }
          if let item = model.player?.currentItem, item.status == .readyToPlay {
            if audio == nil, let track = try? await item.asset.loadTracks(withMediaType: .audio).first,
              let probe = try? PlaybackAudioProbe() { probe.attach(to: item, track: track); audio = probe }
            if (model.player?.currentTime().seconds ?? 0) > 2, model.testDecodedFrame() != nil { frame = true; if (audio?.result.frames ?? 0) > 0 { break } }
          }
          try? await Task.sleep(for: .milliseconds(100))
        }
        checks["watchlistRealPartResolvesAgainAndDecodes"] = frame
        checks["watchlistRealPartHasAudioPCM"] = (audio?.result.frames ?? 0) > 0
      }
    } catch {
      checks["watchlistUnexpectedFailure"] = false
      if let data = try? JSONSerialization.data(withJSONObject: ["error": String(error.localizedDescription.prefix(600))]) { try? data.write(to: output.appendingPathComponent("watchlist-fixture-error.json")) }
    }
    return checks
  }
}

private func watchlistRequireContext(_ context: PlaybackHistoryContext?) throws -> PlaybackHistoryContext {
  guard let context else { throw MTVError.message("缺少自有片源保存信息") }; return context
}

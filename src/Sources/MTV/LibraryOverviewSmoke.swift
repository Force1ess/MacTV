import AVFoundation
import AppKit
import MTVCore

extension UISmoke {
  static func libraryOverviewSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    await model.waitForSourceSave()
    let original = model.captureLibrarySource()
    let oldSource = model.sourceStore, oldSources = model.savedSources.store, oldIndex = model.libraryIndex
    let oldNAS = model.smbLibraryIndex, oldProfiles = model.smb.profileStore, oldEngine = model.preferredEngine
    defer {
      model.libraryOverview.close(); model.stopPlayback(); model.smb.close()
      model.smb.connectionObserverForTesting = nil
      model.sourceStore = oldSource; model.savedSources.store = oldSources; model.libraryIndex = oldIndex
      model.smbLibraryIndex = oldNAS; model.smb.profileStore = oldProfiles; model.preferredEngine = oldEngine
      model.restoreLibrarySource(original); model.navigate(.home)
    }
    let root = output.appendingPathComponent("overview-owned-fixtures")
    let a = root.appendingPathComponent("Films A"), b = root.appendingPathComponent("Films B")
    var checks: [String: Bool] = [:]
    func wait(_ condition: () -> Bool, attempts: Int = 200) async {
      for _ in 0..<attempts { if condition() { return }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    do {
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/PlaybackFixture.mp4")
      for folder in [a, b] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: folder.appendingPathComponent("Film.mp4"))
        let title = folder == a ? "海边的旅程" : "夜航"
        try Data("<movie><title>\(title)</title><plot>仅用于来源切换验证的生成影片。</plot></movie>".utf8).write(to: folder.appendingPathComponent("Film.nfo"))
      }
      model.sourceStore = LibrarySourceStore(file: root.appendingPathComponent("selected.json"))
      model.savedSources.store = SavedLibrarySourcesStore(file: root.appendingPathComponent("sources.json"))
      model.libraryIndex = LibraryIndexStore(file: root.appendingPathComponent("index.json"))
      model.smb.profileStore = SMBProfileStore(file: root.appendingPathComponent("profiles.json"))
      model.smbLibraryIndex = SMBLibraryIndexStore(root: root.appendingPathComponent("nas-index"))
      model.preferredEngine = .system
      for (folder, title) in [(a, "测试硬盘 A"), (b, "测试硬盘 B")] {
        try await model.libraryIndex.save(items: LibraryScanner.scan(root: folder), root: folder)
        try await model.savedSources.store.remember(LibrarySourceSelection(path: folder.path), title: title)
      }
      let profile = try SMBProfile(address: "unreachable.invalid/Films", username: "", guest: true, rememberPassword: false)
      try await model.smb.profileStore.upsert(profile)
      try await model.savedSources.store.remember(LibrarySourceSelection(smbProfileID: profile.id), title: "离线 NAS")
      let mount = root.appendingPathComponent("never-mounted")
      let file = mount.appendingPathComponent("Offline.mp4")
      var item = try LibraryScanner.scan(root: a)[0]
      item.id = file.path; item.url = file.absoluteString; item.title = "离线收藏"
      try await model.smbLibraryIndex.save(SMBMediaIdentity.remap([item], profile: profile, mount: mount), profile: profile, mount: mount)
      var connections = 0
      model.smb.connectionObserverForTesting = { _, _, _, _ in connections += 1 }
      model.useLocalRoot(a)
      await wait { !model.libraryRefreshing }
      await model.waitForSourceSave()
      model.navigate(.library); model.focus.select(row: 1, column: model.overviewColumn); model.handle(.select)
      model.handle(.select)
      await settle()
      checks["overviewReturnDuringLoadingCancelsPresentation"] = !model.libraryOverview.isPresented
      model.presentLibraryOverview()
      await wait { model.libraryOverview.isPresented && !model.libraryOverview.loading }
      checks["overviewRemoteEntryLoadsThreeSources"] = model.libraryOverview.sections.count == 3
      checks["overviewBrowsingDoesNotConnectNAS"] = connections == 0 && !model.smb.isPresented
      checks["overviewBothLocalRootsRemainDistinct"] = model.libraryOverview.sections.prefix(2).map { $0.cards.first?.title } == ["海边的旅程", "夜航"]
      await settle(); capture(window, to: output.appendingPathComponent("overview.png"))
      if let pendingRow = model.libraryOverview.rows.firstIndex(where: { if case .cards(let section, _) = $0 { return section == 1 }; return false }) {
        model.libraryOverview.row = pendingRow; model.libraryOverview.column = 0; model.handle(.select)
      }
      model.libraryOverview.row = 0; model.libraryOverview.column = 2; model.handle(.select)
      await settle()
      checks["overviewSearchCancelsLateCardOpen"] = model.libraryOverview.isPresented && model.keyboardVisible && model.mediaRoot == a.path && model.detail == nil
      checks["overviewSearchOpensOwnScreenKeyboard"] = model.keyboardVisible && model.textEntryTarget == .overviewSearch
      for key in ["y", "e", "h", "a", "n", "g"] { model.pressKey(key) }
      let searchCandidates = model.candidates
      if let candidate = model.candidates.firstIndex(of: "夜航") {
        model.candidateIndex = candidate; model.commitCandidate()
      }
      checks["overviewSearchUsesNativeChineseComposition"] = model.inputText == "夜航"
      if let data = try? JSONSerialization.data(withJSONObject: ["candidates": searchCandidates, "committed": model.inputText], options: [.prettyPrinted]) {
        try? data.write(to: output.appendingPathComponent("generated-search-input.json"))
      }
      model.pressKey("完成")
      await wait { !model.libraryOverview.loading }
      checks["overviewSearchFiltersAcrossSourcesWithoutChangingLocalQuery"] = !model.keyboardVisible && model.libraryOverview.query == "夜航"
        && model.libraryOverview.sections.count == 1 && model.libraryOverview.sections.first?.source.path == b.path && model.search.isEmpty
      await settle(); capture(window, to: output.appendingPathComponent("overview-search.png"))
      func selectCard(section: Int) {
        if let row = model.libraryOverview.rows.firstIndex(where: { if case .cards(let index, _) = $0 { return index == section }; return false }) {
          model.libraryOverview.row = row; model.libraryOverview.column = 0; model.handle(.select)
        }
      }
      selectCard(section: 0)
      let selectedRow = model.libraryOverview.row
      await wait { model.detail?.title == "夜航" && model.mediaRoot == b.path }
      checks["overviewCardSwitchesToItsOwnSourceAndDetail"] = model.detail?.title == "夜航" && model.mediaRoot == b.path
      model.handle(.select)
      var decoded = false
      await wait { decoded = model.player?.currentItem?.status == .readyToPlay && model.testDecodedFrame() != nil; return decoded }
      checks["overviewSelectedSourceActualVideoDecoded"] = decoded && model.playbackTitle == "夜航"
      model.handle(.back); model.handle(.back); model.handle(.back)
      checks["overviewBackRestoresOverviewFocus"] = model.libraryOverview.isPresented && model.libraryOverview.row == selectedRow
      checks["overviewBackPreservesSearchResults"] = model.libraryOverview.query == "夜航" && model.libraryOverview.sections.count == 1
      await settle(); capture(window, to: output.appendingPathComponent("overview-return-focus.png"))
      model.libraryOverview.row = 0; model.libraryOverview.column = 3; model.handle(.select)
      await wait { !model.libraryOverview.loading }
      checks["overviewClearSearchRestoresAllSources"] = model.libraryOverview.query.isEmpty && model.libraryOverview.sections.count == 3
      model.libraryOverview.row = 0; model.libraryOverview.column = 2; model.handle(.select)
      model.inputText = "不会提交的搜索"; model.handle(.back)
      checks["overviewSearchCancelDiscardsOnlyDraft"] = !model.keyboardVisible && model.libraryOverview.query.isEmpty && model.libraryOverview.sections.count == 3
      model.showOverviewKeyboard(); model.inputText = "never-present-generated-title"; model.pressKey("完成")
      await wait { !model.libraryOverview.loading }
      checks["overviewNoResultsKeepsCurrentSource"] = model.libraryOverview.sections.isEmpty && model.libraryOverview.message.contains("没有找到") && model.mediaRoot == b.path
      model.libraryOverview.row = 0; model.libraryOverview.column = 3; model.handle(.select)
      await wait { !model.libraryOverview.loading }
      selectCard(section: 2)
      await wait { model.detail?.title == "离线收藏" && model.needsSMBReconnect }
      checks["overviewOfflineNASDetailHasNoStaleFileURL"] = model.detail?.title == "离线收藏" && model.detail?.url == nil && connections == 0 && !model.smb.isPresented
      model.handle(.select)
      await wait { model.smb.isPresented }
      checks["overviewOfflinePlayRequiresExplicitConnection"] = model.smb.isPresented && connections == 0
      model.handle(.back)
      model.handle(.back); model.handle(.back)
      if let removed = model.libraryOverview.sections.first(where: { $0.source.path == b.path }) {
        _ = try await model.savedSources.store.remove(removed.id)
        selectCard(section: 1)
        await wait { model.notice != nil }
        checks["overviewRemovedSourceCannotReopenFromStaleCard"] = model.libraryOverview.isPresented && model.notice?.contains("发生变化") == true && model.needsSMBReconnect
        model.notice = nil
      }
      await model.waitForSourceSave()
      model.libraryOverview.close()
      model.selectSavedSource(LibrarySourceSelection(smbProfileID: profile.id))
      model.navigate(.home)
      await settle()
      checks["overviewLeavingCancelsPendingSourceNavigation"] = model.section == .home && !model.libraryOverview.isPresented
    } catch { checks["overviewFixtureSetup"] = false }
    return checks
  }
}

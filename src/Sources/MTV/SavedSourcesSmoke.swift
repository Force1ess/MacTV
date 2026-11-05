import AppKit
import MTVCore

extension UISmoke {
  static func savedSourcesSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    await model.waitForSourceSave()
    let original = model.captureLibrarySource()
    let oldSourceStore = model.sourceStore, oldCatalog = model.savedSources.store
    let oldIndex = model.libraryIndex, oldMetadata = model.metadataStore
    let oldProfiles = model.smb.profileStore
    let root = output.appendingPathComponent("saved-sources")
    let a = root.appendingPathComponent("Films A"), b = root.appendingPathComponent("Films B")
    let away = root.appendingPathComponent("Films A Offline")
    defer {
      model.savedSources.close(); model.localFolders.close(); model.smb.close()
      model.smb.connectionObserverForTesting = nil
      model.sourceStore = oldSourceStore; model.savedSources.store = oldCatalog
      model.libraryIndex = oldIndex; model.metadataStore = oldMetadata; model.smb.profileStore = oldProfiles
      model.restoreLibrarySource(original); model.navigate(.home)
    }
    var checks: [String: Bool] = [:]
    func ready() async {
      for _ in 0..<300 {
        if !model.libraryRefreshing && !model.savedSources.loading { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      await model.waitForSourceSave()
    }
    do {
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/MTV/Fixtures/PlaybackFixture.mp4")
      for directory in [a, b] {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: directory.appendingPathComponent("\(directory.lastPathComponent).2024.mp4"))
      }
      model.sourceStore = LibrarySourceStore(file: root.appendingPathComponent("active.json"))
      model.savedSources.store = SavedLibrarySourcesStore(file: root.appendingPathComponent("sources.json"))
      model.libraryIndex = LibraryIndexStore(file: root.appendingPathComponent("index.json"))
      model.metadataStore = MetadataStore(file: root.appendingPathComponent("matches.json"))
      model.smb.profileStore = SMBProfileStore(file: root.appendingPathComponent("nas.json"))
      model.useLocalRoot(a); await ready()
      model.useLocalRoot(b); await ready()
      await openSettingWithRemote(.sources, model: model)
      await ready()
      checks["savedSourcesReachableWithRemoteFromSettings"] = model.savedSources.isPresented
        && model.savedSources.sources.count == 2
      await settle()
      capture(window, to: output.appendingPathComponent("34-content-sources.png"))
      try FileManager.default.moveItem(at: a, to: away)
      guard let first = model.savedSources.sources.firstIndex(where: { $0.path == a.path }) else {
        throw MTVError.message("来源测试缺少 A")
      }
      model.savedSources.selection = first; model.savedSources.column = 0; model.handle(.select)
      await ready()
      checks["savedSourceSwitchRestoresOfflineLocalCache"] = model.mediaRoot == a.path
        && model.library.count == 1 && model.libraryNeedsAttention && model.libraryIndexedAt != nil
        && model.library.first?.id.hasPrefix(a.path + "/") == true
      model.focus.select(row: 1, column: model.savedSourcesColumn); model.handle(.select); await ready()
      checks["savedSourcesReachableWithRemoteFromLibrary"] = model.savedSources.isPresented
      guard let second = model.savedSources.sources.firstIndex(where: { $0.path == b.path }) else {
        throw MTVError.message("来源测试缺少 B")
      }
      model.savedSources.selection = second; model.handle(.right); model.handle(.select)
      model.savedSources.close()
      await model.savedSources.waitForPendingChanges()
      model.presentSavedSources(); await ready()
      checks["savedSourceConfirmedRemovalFinishesAfterPanelDismissal"] = model.savedSources.sources.count == 1
      let retained = try await model.libraryIndex.load(root: b)
      checks["savedSourceRemovalPreservesMediaAndIndex"] = model.savedSources.sources.count == 1
        && FileManager.default.fileExists(atPath: b.path)
        && retained?.items.count == 1
      let status = model.libraryStatus
      model.savedSources.selection = 0; model.savedSources.column = 0; model.handle(.select)
      checks["savedSourceCurrentSelectionDoesNotRestartScan"] = !model.savedSources.isPresented
        && !model.libraryRefreshing && model.libraryStatus == status && model.mediaRoot == a.path
      model.presentSavedSources(); await ready()
      model.savedSources.selection = model.savedSources.sources.count; model.savedSources.column = 0
      model.handle(.select)
      checks["savedSourcesAddFolderOpensTVPicker"] = model.localFolders.isPresented && !model.savedSources.isPresented
      model.handle(.back)
      let missing = LibrarySourceSelection(smbProfileID: UUID())
      _ = try await model.savedSources.store.remember(missing, title: "已删除连接")
      model.presentSavedSources(); await ready()
      guard let deleted = model.savedSources.sources.firstIndex(where: { $0.matches(missing) }) else {
        throw MTVError.message("来源测试缺少失效 NAS")
      }
      model.savedSources.selection = deleted; model.savedSources.column = 0; model.handle(.select)
      let deletedSourceMessage = L("此来源的 NAS 连接已删除，请重新添加或移除该来源")
      for _ in 0..<100 {
        if model.sourceError == deletedSourceMessage { break }
        try? await Task.sleep(for: .milliseconds(30))
      }
      let stillActive = try await model.sourceStore.load()
      checks["savedMissingNASDoesNotReplaceCurrentSource"] = model.mediaRoot == a.path
        && stillActive?.path == a.path && model.sourceError == deletedSourceMessage
      let profile = try SMBProfile(address: "fixture.invalid/Movies", username: "", guest: true, rememberPassword: false)
      _ = try await model.smb.profileStore.upsert(profile)
      _ = try await model.savedSources.store.remember(LibrarySourceSelection(smbProfileID: profile.id), title: "测试 NAS")
      var requests = 0
      model.smb.connectionObserverForTesting = { _, _, _, _ in requests += 1 }
      model.presentSavedSources(); await ready()
      guard let nas = model.savedSources.sources.firstIndex(where: { $0.smbProfileID == profile.id }) else {
        throw MTVError.message("来源测试缺少 NAS")
      }
      model.savedSources.selection = nas; model.savedSources.column = 0; model.handle(.select)
      for _ in 0..<200 {
        if model.needsSMBReconnect && !model.libraryRefreshing { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      await model.waitForSourceSave()
      let selected = try await model.sourceStore.load()
      checks["savedNASSourceSwitchDoesNotAuthenticateOrMount"] = model.needsSMBReconnect
        && !model.smb.isPresented && requests == 0 && model.mediaRoot.isEmpty
        && selected?.smbProfileID == profile.id
      model.presentSavedSources(); await ready()
      guard let activeNAS = model.savedSources.sources.firstIndex(where: { $0.smbProfileID == profile.id }) else {
        throw MTVError.message("来源测试缺少当前 NAS")
      }
      model.savedSources.selection = activeNAS; model.savedSources.column = 1; model.handle(.select)
      model.savedSources.close()
      await model.savedSources.waitForPendingChanges(); await model.waitForSourceSave()
      let emptied = try await model.sourceStore.load()
      checks["activeSourceRemovalKeepsRemainingLocalSource"] = model.captureLibrarySource().smbProfile == nil
        && model.mediaRoot == a.path && emptied?.path == a.path
      model.presentSavedSources(); await ready()
      checks["removedActiveSourceIsNotRestoredWhenReopeningList"] = !model.savedSources.sources.contains { $0.smbProfileID == profile.id }
      checks["activeSourceRemovalKeepsNASAccount"] = try await model.smb.profileStore.load().contains { $0.id == profile.id }
      model.selectSavedSource(missing)
      model.useLocalRoot(b)
      await ready()
      let latest = try await model.sourceStore.load()
      checks["savedSourceNewerLocalChoiceCancelsPendingNASChoice"] = model.mediaRoot == b.path
        && !model.needsSMBReconnect && latest?.path == b.path && model.sourceError == nil
    } catch { checks["savedSourcesFixtureFlow"] = false }
    return checks
  }
}

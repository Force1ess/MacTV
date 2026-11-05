import AVFoundation
import AppKit
import MTVCore
import Vision

extension UISmoke {
  static func movieVersionsSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    await model.waitForSourceSave()
    let original = model.captureLibrarySource(), oldSource = model.sourceStore, oldSources = model.savedSources.store
    let oldIndex = model.libraryIndex, oldNAS = model.smbLibraryIndex, oldProfiles = model.smb.profileStore, oldEngine = model.preferredEngine
    defer {
      model.libraryOverview.close(); model.stopPlayback(); model.smb.close(); model.smb.connectionObserverForTesting = nil
      model.sourceStore = oldSource; model.savedSources.store = oldSources; model.libraryIndex = oldIndex
      model.smbLibraryIndex = oldNAS; model.smb.profileStore = oldProfiles; model.preferredEngine = oldEngine
      model.detail = nil; model.notice = nil; model.restoreLibrarySource(original); model.navigate(.home)
    }
    var checks: [String: Bool] = [:]
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<240 { if condition() { return }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    func visibleText(_ expected: String) -> Bool {
      guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      guard let image = bitmap.cgImage else { return false }
      let request = VNRecognizeTextRequest(); request.recognitionLanguages = ["en-US"]; request.recognitionLevel = .accurate
      do {
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined().replacingOccurrences(of: " ", with: "").contains(expected)
      } catch { return false }
    }
    let root = output.appendingPathComponent("owned-version-fixtures"), a = root.appendingPathComponent("Disk A"), b = root.appendingPathComponent("Disk B")
    do {
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/IndependentLongGOP45-v1.mp4")
      for (folder, name, id) in [(a, "Night.Standard.1080p", 603), (a, "Night.Extended.2160p", 603),
        (a, "Night.Remake", 604), (a, "Night.Unknown", 0), (b, "Night.Archive", 603)] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: folder.appendingPathComponent(name + ".mp4"))
        let identity = id > 0 ? "<uniqueid type=\"tmdb\">\(id)</uniqueid>" : ""
        try Data("<movie><title>夜航</title><year>2026</year>\(identity)</movie>".utf8)
          .write(to: folder.appendingPathComponent(name + ".nfo"))
      }
      let artwork = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/GeneratedPoster.png")
      if let image = NSImage(contentsOf: artwork)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
        let data = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [:]) {
        for folder in [a, b] { try data.write(to: folder.appendingPathComponent("poster.jpg")) }
      }
      model.sourceStore = LibrarySourceStore(file: root.appendingPathComponent("selected.json"))
      model.savedSources.store = SavedLibrarySourcesStore(file: root.appendingPathComponent("sources.json"))
      model.libraryIndex = LibraryIndexStore(file: root.appendingPathComponent("index.json"))
      model.smb.profileStore = SMBProfileStore(file: root.appendingPathComponent("profiles.json"))
      model.smbLibraryIndex = SMBLibraryIndexStore(root: root.appendingPathComponent("nas")); model.preferredEngine = .system
      for (folder, title) in [(a, "客厅硬盘"), (b, "收藏硬盘")] {
        try await model.libraryIndex.save(items: LibraryScanner.scan(root: folder), root: folder)
        try await model.savedSources.store.remember(LibrarySourceSelection(path: folder.path), title: title)
      }
      let profile = try SMBProfile(address: "unreachable.invalid/Movies", username: "", guest: true, rememberPassword: false)
      try await model.smb.profileStore.upsert(profile)
      try await model.savedSources.store.remember(LibrarySourceSelection(smbProfileID: profile.id), title: "离线 NAS")
      let mount = root.appendingPathComponent("never-mounted")
      let localA = try LibraryScanner.scan(root: a).first { $0.id.hasSuffix("Night.Standard.1080p.mp4") }!
      let localB = try LibraryScanner.scan(root: b)[0]
      var nasItem = localA; nasItem.id = mount.appendingPathComponent("Night.NAS.mkv").path; nasItem.url = URL(fileURLWithPath: nasItem.id).absoluteString
      try await model.smbLibraryIndex.save(SMBMediaIdentity.remap([nasItem], profile: profile, mount: mount), profile: profile, mount: mount)
      var connections = 0; model.smb.connectionObserverForTesting = { _, _, _, _ in connections += 1 }
      model.useLocalRoot(a); await wait { !model.libraryRefreshing }; await model.waitForSourceSave()
      try await model.savedSources.store.remember(LibrarySourceSelection(path: a.path), title: "客厅硬盘")
      model.resumeStore.save(5, for: localA.id, duration: 45); model.resumeStore.save(12, for: localB.id, duration: 45)
      model.navigate(.library); model.presentLibraryOverview(); await wait { !model.libraryOverview.loading }
      func selectCard(_ id: String) {
        for (row, value) in model.libraryOverview.rows.enumerated() {
          if case .cards(let section, let range) = value,
            let index = range.first(where: { model.libraryOverview.sections[section].cards[$0].id == id }) {
            model.libraryOverview.row = row; model.libraryOverview.column = index - range.lowerBound; model.handle(.select); return
          }
        }
      }
      func waitForVersions() async { await wait { model.libraryOverview.versionsPresented && !model.libraryOverview.versionsLoading } }
      let storedB = try await model.savedSources.store.load().first { $0.path == b.path }!
      model.libraryOverview.onOpen?(storedB, nil)
      selectCard(localA.id); await waitForVersions()
      let controller = model.libraryOverview
      checks["versionsNewPickerInvalidatesEarlierSourceOpen"] = controller.versionsPresented && model.mediaRoot == a.path && model.detail == nil
      checks["versionsExplicitMovieIDFindsTwoLocalCopiesOtherDiskAndNAS"] = controller.versions.count == 4
        && controller.versions.allSatisfy { $0.card.movieTMDBID == 603 } && connections == 0
      checks["versionsKeepDistinctSourceAndFileIdentities"] = Set(controller.versions.map(\.id)).count == 4
        && controller.versions.contains { $0.card.filename == "Night.NAS.mkv" && $0.card.offline }
      let row = controller.row, column = controller.column
      await settle(); capture(window, to: output.appendingPathComponent("movie-versions.png"))
      model.handle(.back)
      checks["versionsRemoteBackReturnsToOriginalWallCard"] = !controller.versionsPresented && controller.isPresented && controller.row == row && controller.column == column
      model.handle(.select); await waitForVersions()
      if let index = controller.versions.firstIndex(where: { $0.source.path == b.path }) {
        while controller.versionIndex < index { model.handle(.down) }
        while controller.versionIndex > index { model.handle(.up) }
        model.handle(.select)
      }
      await wait { model.detail?.id == localB.id && model.mediaRoot == b.path }
      checks["versionsRemoteChoosesOtherDiskWithoutLosingProgressIdentity"] = model.detail?.id == localB.id
        && model.resumeStore.position(for: localB.id) == 12 && model.resumeStore.position(for: localA.id) == 5
      model.handle(.select)
      await wait { model.testDecodedFrame() != nil && (model.player?.currentTime().seconds ?? 0) >= 11 }
      checks["versionsChosenFileActuallyResumesAndDecodes"] = model.testDecodedFrame() != nil
        && abs((model.player?.currentTime().seconds ?? -100) - 12) < 3 && model.playbackInterruption == nil
      model.handle(.back); model.handle(.back); model.handle(.back)
      checks["versionsPlaybackBackRestoresOverviewAnchor"] = controller.isPresented && controller.row == row && controller.column == column
        && model.resumeStore.position(for: localA.id) == 5
      model.handle(.select); await waitForVersions()
      if let index = controller.versions.firstIndex(where: { $0.source.smbProfileID == profile.id }) {
        while controller.versionIndex < index { model.handle(.down) }; while controller.versionIndex > index { model.handle(.up) }
        await settle(); capture(window, to: output.appendingPathComponent("movie-versions-nas.png"))
        checks["versionsRemoteSelectionScrollsNASFilenameIntoActualViewport"] = visibleText("Night.NAS.mkv")
        model.handle(.select)
      }
      await wait { model.needsSMBReconnect && model.detail != nil }
      checks["versionsOfflineNASHasNoMediaURLAndDoesNotAutoConnect"] = model.needsSMBReconnect && model.detail?.url == nil && connections == 0 && !model.smb.isPresented
      model.handle(.select); await wait { model.smb.isPresented }
      checks["versionsOfflinePlaybackRequiresExplicitConnection"] = model.smb.isPresented && connections == 0
      for _ in 0..<6 { if controller.isPresented { break }; model.handle(.back) }
      await model.waitForSourceSave()
      model.libraryOverview.close()
      model.libraryOverview.setQuery("客厅硬盘"); model.presentLibraryOverview(); await wait { !controller.loading }
      selectCard(localA.id); await waitForVersions()
      checks["versionsQueryHiddenOtherDiskStillAvailable"] = controller.sections.count == 1 && controller.versions.count == 4
      if let data = try? JSONSerialization.data(withJSONObject: ["query": controller.query,
        "sourceTitles": controller.sections.map { $0.source.title }, "sourceCount": controller.sections.count,
        "versionCount": controller.versions.count, "pickerPresented": controller.versionsPresented, "notice": model.notice ?? ""]) {
        try? data.write(to: output.appendingPathComponent("versions-search-evidence.json"))
      }
      model.handle(.back)
      let removed = try await model.savedSources.store.load().first { $0.path == b.path }!
      selectCard(localA.id); await waitForVersions()
      _ = try await model.savedSources.store.remove(removed.id)
      if let index = controller.versions.firstIndex(where: { $0.source.id == removed.id }) { controller.versionIndex = index; model.handle(.select) }
      await wait { model.notice != nil }
      checks["versionsRemovedSourceCannotOpenFromStalePicker"] = controller.isPresented && model.notice?.contains("发生变化") == true
      model.notice = nil; model.handle(.back)
      selectCard(localA.id); model.handle(.back)
      await settle()
      checks["versionsBackCancelsPendingLookupWithoutOpeningContent"] = !controller.versionsPresented && controller.isPresented && model.detail == nil
      await model.waitForSourceSave()
    } catch {
      checks["versionsOwnedFixtureFlowCompleted"] = false
      try? Data(error.localizedDescription.utf8).write(to: output.appendingPathComponent("versions-error.txt"))
    }
    return checks
  }
}

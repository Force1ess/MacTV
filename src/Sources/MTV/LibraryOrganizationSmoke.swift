import AppKit
import MTVCore

extension UISmoke {
  @MainActor static func libraryOrganizationSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    func wait(_ predicate: () -> Bool) async {
      for _ in 0..<300 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(40)) }
    }
    let root = output.appendingPathComponent("owned-organization")
    let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/PlaybackFixture.mp4")
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      for name in ["Show S01E01.mp4", "Show S01E01-79c6d977bf5f.mp4"] {
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent(name))
      }
      model.useLocalRoot(root); await wait { !model.libraryRefreshing && model.library.count == 2 }
      guard let show = model.libraryCatalog.root.first(where: { $0.kind == .series }) else { checks["seriesDiscovered"] = false; return checks }
      model.selectContent(show)
      checks["seriesSkipsSeasonDirectories"] = model.currentLibraryItems.count == 1 && model.currentLibraryItems.first?.kind == .versions
      guard let versions = model.currentLibraryItems.first else { return checks }
      model.selectContent(versions)
      let path = model.libraryPath.map(\.id)
      checks["versionPickerContainsEveryFile"] = model.currentLibraryItems.count == 2 && model.currentLibraryItems.allSatisfy { $0.url != nil }
      try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent("Show S01E02.mp4"))
      model.scanLibrary(); await wait { !model.libraryRefreshing && model.library.count == 3 }
      checks["backgroundRefreshKeepsVersionDirectory"] = model.libraryPath.map(\.id) == path && model.currentLibraryItems.count == 2
      let report = LibraryInventoryReport(root: root, basis: "app-owned-test", files: model.libraryFilesForMaintenance)
      checks["programmaticDisplayGraphMatchesVisibleVersionPicker"] = report.displayCollections[versions.id]?.map(\.id) == model.currentLibraryItems.map(\.id)
        && report.summary.unreachableFiles == 0 && report.summary.files == 3
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(report).write(to: output.appendingPathComponent("inventory.json"))
      await settle(); capture(window, to: output.appendingPathComponent("versions-after-refresh.png"))
      guard let video = model.currentLibraryItems.first else { return checks }
      model.preferredEngine = .system; model.playbackVolume = 0
      model.activateCard(video); await wait { model.playbackPresented && model.duration > 0 }
      checks["versionCardStartsPlaybackDirectly"] = model.playbackPresented && model.playingItem?.id == video.id
      model.showPlayerControls(); model.handle(.back)
      checks["playbackBackFirstHidesHUD"] = model.playbackPresented && !model.playerControlsVisible
      model.handle(.back); await model.waitForPlaybackShutdown()
      checks["playbackBackReturnsToSameVersionDirectory"] = !model.playbackPresented && model.libraryPath.map(\.id) == path
      model.handle(.back)
      checks["versionBackReturnsToEpisodesIncludingNewDownload"] = model.libraryPath.map(\.id) == [show.id] && model.currentLibraryItems.count == 2
      model.handle(.back)
      checks["seriesBackReturnsToLibrary"] = model.libraryPath.isEmpty && model.section == .library
    } catch { checks["ownedOrganizationSetup"] = false }
    model.stopPlayback(); await model.waitForPlaybackShutdown()
    return checks
  }
}

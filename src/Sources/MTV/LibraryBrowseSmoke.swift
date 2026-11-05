import AVFoundation
import AppKit
import MTVCore

extension UISmoke {
  static func libraryBrowseSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    let original = model.captureLibrarySource(), oldOptions = model.libraryBrowseOptions, oldEngine = model.preferredEngine
    let originalKind = UserDefaults.standard.string(forKey: "mtv.library.kind"), originalOrder = UserDefaults.standard.string(forKey: "mtv.library.order")
    defer {
      model.libraryBrowser.close(); model.stopPlayback(); model.applyLibraryBrowse(oldOptions); model.preferredEngine = oldEngine
      model.notice = nil; model.detail = nil; model.search = ""; model.restoreLibrarySource(original); model.navigate(.home)
    }
    var checks: [String: Bool] = [:]
    func wait(_ condition: () -> Bool) async { for _ in 0..<240 { if condition() { return }; try? await Task.sleep(for: .milliseconds(40)) } }
    func open() { model.focus.select(row: 1, column: model.libraryBrowseColumn); model.handle(.select) }
    func apply(_ kind: LibraryBrowseKind, _ order: LibraryBrowseOrder) {
      open(); let controller = model.libraryBrowser
      controller.row = 0; controller.column = LibraryBrowseKind.allCases.firstIndex(of: kind)!; model.handle(.select)
      open(); controller.row = 1; controller.column = LibraryBrowseOrder.allCases.firstIndex(of: order)!; model.handle(.select)
    }
    do {
      let root = output.appendingPathComponent("owned-browse-fixtures")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/PlaybackFixture.mp4")
      for (name, title, year) in [("Movie2", "远行 2", 1999), ("Movie10", "远行 10", 2024)] {
        try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent(name + ".mp4"))
        try Data("<movie><title>\(title)</title><year>\(year)</year></movie>".utf8).write(to: root.appendingPathComponent(name + ".nfo"))
      }
      let season = root.appendingPathComponent("Demo/Season 1")
      try FileManager.default.createDirectory(at: season, withIntermediateDirectories: true)
      for name in ["Demo.S01E01.Zeta", "Demo.S01E02.Alpha"] { try FileManager.default.copyItem(at: fixture, to: season.appendingPathComponent(name + ".mp4")) }
      model.useLocalRoot(root); await wait { !model.libraryRefreshing }; await model.waitForSourceSave()
      model.navigate(.library); model.applyLibraryBrowse(LibraryBrowseOptions())
      checks["browseRootStartsWithAllThreeCards"] = model.filtered.count == 3 && model.focus.rows[1] == 4
      model.focus.select(row: 1, column: model.overviewColumn)
      model.handle(.right); model.handle(.select)
      checks["browseRemoteToolbarEntryIsReachable"] = model.libraryBrowser.isPresented && model.focus.column == model.libraryBrowseColumn
      model.handle(.right); model.handle(.select)
      checks["browseSelectionAppliesImmediately"] = !model.libraryBrowser.isPresented && model.libraryBrowseOptions.kind == .movies && model.filtered.count == 2
      open(); await settle(); capture(window, to: output.appendingPathComponent("browse-options.png"))
      model.handle(.back)
      checks["browseBackKeepsAppliedSelection"] = !model.libraryBrowser.isPresented && model.libraryBrowseOptions.kind == .movies
      apply(.movies, .newestYear)
      checks["browseMovieFilterAndYearSortApplyTogether"] = model.filtered.map(\.title) == ["远行 10", "远行 2"]
        && model.focus.row == 2 && model.focus.column == 0 && !model.libraryBrowser.isPresented
      await settle(); capture(window, to: output.appendingPathComponent("browse-movies-year.png"))
      model.preferredEngine = .system; model.handle(.select)
      await wait { model.player?.currentItem?.status == .readyToPlay && model.testDecodedFrame() != nil }
      checks["browseSelectedSortedMovieActuallyDecodes"] = model.playbackTitle == "远行 10" && model.testDecodedFrame() != nil
      model.handle(.back)
      checks["browseDetailReturnKeepsFilteredOrderAndFocus"] = model.libraryPath.isEmpty && model.filtered.map(\.title) == ["远行 10", "远行 2"] && model.focus.row == 2 && model.focus.column == 0
      apply(.series, .reverseTitle)
      model.handle(.select)
      checks["browseRootSortCannotReorderSeasonEpisodes"] = model.libraryPath.count == 1 && model.filtered.map { $0.localMetadata?.episode } == [1, 2]
        && model.filtered.map(\.title) == ["Zeta", "Alpha"]
      model.handle(.back)
      checks["browseSeriesBackRestoresRootFilter"] = model.libraryPath.isEmpty && model.libraryBrowseOptions.kind == .series && model.filtered.count == 1
      model.focus.select(row: 1, column: 0); model.handle(.select)
      model.inputText = "2024"; model.pressKey("完成")
      checks["browseZeroResultKeepsIndexAndRecoveryEntry"] = model.filtered.isEmpty && model.captureLibrarySource().files.count == 4
        && model.focus.rows[1] == 4
      await settle(); capture(window, to: output.appendingPathComponent("browse-empty-category.png"))
      apply(.movies, .newestYear)
      checks["browseRootSearchMatchesMetadataYear"] = model.filtered.map(\.title) == ["远行 10"] && model.search == "2024"
      model.focus.select(row: 1, column: 0); model.handle(.select); model.inputText = ""; model.pressKey("完成")
      let files = model.captureLibrarySource().files
      var replacement = files
      if let index = replacement.firstIndex(where: { $0.title == "远行 10" }) { replacement[index].title = "更新后的影片" }
      _ = model.filtered; model.applyLibraryItems(replacement, preservingPosition: true)
      checks["browseMetadataRefreshInvalidatesCachedResults"] = model.filtered.first?.title == "更新后的影片" && model.filtered.count == 2
      model.applyLibraryItems(files, preservingPosition: true)
      open(); model.handle(.back)
      checks["browseBackKeepsAppliedSettings"] = model.libraryBrowseOptions == LibraryBrowseOptions(kind: .movies, order: .newestYear) && !model.libraryBrowser.isPresented
      checks["browseUITestDoesNotWriteNormalPreferences"] = UserDefaults.standard.string(forKey: "mtv.library.kind") == originalKind && UserDefaults.standard.string(forKey: "mtv.library.order") == originalOrder
      await model.waitForSourceSave()
    } catch { checks["browseOwnedFixtureFlowCompleted"] = false; try? Data(error.localizedDescription.utf8).write(to: output.appendingPathComponent("browse-error.txt")) }
    return checks
  }
}

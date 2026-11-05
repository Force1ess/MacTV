import AppKit
import MTVCore

extension UISmoke {
  static func sourceSetupSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String:
    Bool]
  {
    var checks: [String: Bool] = [:]
    let oldPreference = UserDefaults.standard.string(forKey: "mediaRoot")
    func waitUntilReady() async {
      for _ in 0..<200 {
        if !model.libraryRefreshing && !model.localFolders.loading { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
    do {
      let normalSourceBefore = try await LibrarySourceStore().load()
      let sourceFile = await model.sourceStore.file
      let indexFile = await model.libraryIndex.file
      checks["freshInstallDoesNotInventOrScanSource"] =
        model.sourceSetup.isPresented
        && model.sourceNeedsSetup && model.mediaRoot.isEmpty && model.library.isEmpty
        && !FileManager.default.fileExists(atPath: sourceFile.path)
        && !FileManager.default.fileExists(atPath: indexFile.path)
      model.handle(.down)
      model.handle(.up)
      checks["freshSetupVerticalFocusRestored"] = model.sourceSetup.selection == 0
      await settle()
      capture(window, to: output.appendingPathComponent("27-first-source-setup.png"))
      model.handle(.select)
      await waitUntilReady()
      checks["freshLocalChoiceUsesTVFolderPicker"] =
        model.localFolders.isPresented && !model.sourceSetup.isPresented
      model.handle(.back)
      checks["freshLocalCancelReturnsWithoutSaving"] =
        model.sourceSetup.isPresented
        && !FileManager.default.fileExists(atPath: sourceFile.path)
      model.handle(.right)
      model.handle(.select)
      checks["freshNASChoiceOpensFormWithoutConnecting"] =
        model.smb.isPresented && model.smb.phase == "form"
      model.handle(.back)
      checks["freshNASCancelReturnsToChoices"] =
        model.sourceSetup.isPresented && !model.smb.isPresented
      model.handle(.right)
      model.handle(.right)
      model.handle(.select)
      await model.waitForSourceSave()
      let skipped = try await LibrarySourceStore(file: sourceFile).load()
      checks["freshAppsChoicePersistsExplicitNoLocalSource"] =
        skipped != nil && skipped?.path == nil
        && !model.sourceNeedsSetup && model.section == .extensions && !model.sourceSetup.isPresented
      checks["freshAppsAreIndependentOfLocalLibrary"] =
        model.plugins.contains { $0.id == "mtv.bilibili" }
        && model.plugins.contains { $0.id == "mtv.quark" } && model.library.isEmpty
      model.initializeLibrarySource()
      await waitUntilReady()
      checks["freshExplicitSkipDoesNotReimportAnOldDefault"] =
        model.mediaRoot.isEmpty
        && !model.sourceNeedsSetup && !model.sourceSetup.isPresented
        && !FileManager.default.fileExists(atPath: indexFile.path)
      model.navigate(.home)
      model.focus.select(row: 1, column: 0)
      model.handle(.select)
      checks["freshEmptyHeroCanReopenSourceSetup"] = model.sourceSetup.isPresented
      model.handle(.select)
      await waitUntilReady()
      let root = output.appendingPathComponent("FirstChosenLibrary")
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/MTV/Fixtures/PlaybackFixture.mp4")
      try FileManager.default.copyItem(
        at: fixture, to: root.appendingPathComponent("First.Movie.2024.mp4"))
      model.localFolders.openAddress(root.path)
      await waitUntilReady()
      model.handle(.left)
      model.handle(.select)
      await waitUntilReady()
      await model.waitForSourceSave()
      let chosen = try await LibrarySourceStore(file: sourceFile).load()
      checks["freshChosenDirectoryPersistsAndImports"] =
        chosen?.path == root.standardizedFileURL.path
        && chosen?.origin == .chosen && model.library.count == 1 && !model.sourceSetup.isPresented
      checks["freshTestsLeaveLegacyPreferenceAlone"] =
        UserDefaults.standard.string(forKey: "mediaRoot") == oldPreference
      let normalSourceAfter = try await LibrarySourceStore().load()
      checks["freshSourceProfileIsIsolated"] = sourceFile != LibrarySourceStore.normalFile
        && normalSourceBefore == normalSourceAfter
      await settle()
      capture(window, to: output.appendingPathComponent("28-first-source-imported.png"))
    } catch { checks["freshSetupFixtureFlow"] = false }
    return checks
  }
}

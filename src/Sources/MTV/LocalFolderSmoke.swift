import AppKit
import MTVCore

extension UISmoke {
  static func localFolderSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String:
    Bool]
  {
    let source = model.captureLibrarySource()
    let savedPreference = UserDefaults.standard.string(forKey: "mediaRoot")
    defer {
      if model.keyboardVisible { model.handle(.back) }
      model.localFolders.close()
      model.restoreLibrarySource(source)
      model.navigate(.home)
    }
    var checks: [String: Bool] = [:]
    do {
      let root = output.appendingPathComponent("LocalFolderLibrary")
      for path in ["Movies", "Season 2", "Season 10"] {
        try FileManager.default.createDirectory(
          at: root.appendingPathComponent(path), withIntermediateDirectories: true)
      }
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/MTV/Fixtures/PlaybackFixture.mp4")
      try FileManager.default.copyItem(
        at: fixture, to: root.appendingPathComponent("Movies/Local.Test.2024.mp4"))
      model.mediaRoot = root.path
      await openSettingWithRemote(.addFolder, model: model)
      for _ in 0..<100 {
        if !model.localFolders.loading { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      checks["localFolderRemoteSettingsEntry"] =
        model.localFolders.isPresented
        && model.localFolders.folders.map(\.lastPathComponent) == [
          "Movies", "Season 2", "Season 10",
        ]
      model.handle(.left)
      checks["localFolderLeftSelectsImport"] = model.localFolders.selection == 0
      model.handle(.right)
      checks["localFolderRightSelectsChild"] = model.localFolders.selection == 8
      model.smokeKeyRoute = [:]
      let canReceiveKey = NSApp.isActive && window.isKeyWindow
      if let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}",
        isARepeat: false, keyCode: 123)
      {
        NSApp.postEvent(event, atStart: false)
        try? await Task.sleep(for: .milliseconds(200))
        if canReceiveKey {
          checks["localFolderNativeWindowKeyRoute"] = model.localFolders.selection == 0
        } else {
          checks["localFolderInactiveWindowIgnoresKeys"] =
            model.localFolders.selection == 8
            && model.smokeKeyRoute["active"] == "false"
        }
        var diagnostic = model.smokeKeyRoute
        diagnostic["constructedWindow"] = event.window?.identifier?.rawValue ?? "nil"
        diagnostic["windowVisible"] = String(window.isVisible)
        diagnostic["applicationActive"] = String(NSApp.isActive)
        diagnostic["selection"] = String(model.localFolders.selection)
        diagnostic["nativeWindowKeyRouteVerified"] = String(
          canReceiveKey && model.localFolders.selection == 0)
        if let data = try? JSONSerialization.data(
          withJSONObject: diagnostic, options: [.sortedKeys])
        {
          try? data.write(to: output.appendingPathComponent("key-routing.json"))
        }
      } else {
        checks["localFolderNativeWindowKeyRoute"] = false
      }
      model.handle(.right)
      await settle()
      capture(window, to: output.appendingPathComponent("24-local-folders.png"))
      model.handle(.select)
      for _ in 0..<100 {
        if !model.localFolders.loading { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      checks["localFolderRemoteEntersChild"] =
        model.localFolders.directory?.lastPathComponent == "Movies"
      model.showLocalPath()
      model.pressKey("清空")
      model.handle(.text(root.appendingPathComponent("missing").path))
      checks["localFolderPathUsesOwnScreenKeyboard"] =
        model.keyboardVisible
        && model.textEntryTarget == .localPath && !model.keyboardSecret && model.search.isEmpty
      model.pressKey("完成")
      for _ in 0..<100 {
        if !model.localFolders.loading { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      checks["localFolderFailureKeepsPreviousDirectory"] =
        !model.localFolders.message.isEmpty
        && model.localFolders.directory?.lastPathComponent == "Movies"
      model.handle(.left)
      model.handle(.select)
      for _ in 0..<100 {
        if !model.loading { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      checks["localFolderImportScansSelectedDirectory"] =
        !model.localFolders.isPresented
        && model.section == .library && model.library.count == 1
        && model.library.first?.title == "Local Test"
      checks["localFolderTestDoesNotChangeSavedSource"] =
        UserDefaults.standard.string(forKey: "mediaRoot") == savedPreference
      model.localFolders.present(at: root)
      model.localFolders.close()
      try? await Task.sleep(for: .milliseconds(100))
      checks["localFolderCancelIgnoresLateListing"] =
        !model.localFolders.isPresented
        && model.localFolders.directory == nil
    } catch { checks["localFolderFixtureFlow"] = false }
    return checks
  }
}

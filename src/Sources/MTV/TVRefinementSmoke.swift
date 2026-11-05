import AppKit
import MTVCore

extension UISmoke {
  static func openSettingWithRemote(_ setting: TVSetting, model: AppModel) async {
    if setting == .addFolder || setting == .nas {
      await openSettingWithRemote(.sources, model: model)
      for _ in 0..<120 {
        if !model.savedSources.loading { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      model.savedSources.selection = model.savedSources.sources.count + (setting == .nas ? 1 : 0)
      model.savedSources.column = 0
      model.handle(.select)
      return
    }
    model.navigate(.settings)
    model.settingsGroup = 1; model.settingsSidebarFocus = true
    model.focus.select(row: 0, column: model.visibleNavigationTabs.firstIndex(of: .settings) ?? 0); model.handle(.down)
    for _ in 1..<setting.row { model.handle(.down) }
    model.handle(.right)
    for _ in 0..<setting.column { model.handle(.down) }
    model.handle(.select)
  }
  static func tvRefinementSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    let sourceSnapshot = model.captureLibrarySource()
    let originalTabs = model.navigationTabs
    let appearance = model.appearance, glass = model.glassEnabled
    let savedAppearance = UserDefaults.standard.object(forKey: "mtv.appearance") as? String
    defer {
      model.restoreLibrarySource(sourceSnapshot)
      model.navigationTabs = originalTabs; model.navigationCustomizationVisible = false
      model.appearance = appearance; model.glassEnabled = glass
      model.notice = nil; model.appearanceVisible = false
      model.accountSettingsVisible = false; model.login.close(reload: false)
      model.sourceEditorReturnsToSavedSources = false
      model.localFolders.close(); model.savedSources.close(); model.pluginFolders.close(); model.metadata.close()
      model.automaticMetadata.close(); model.finishSetupGuide(completed: false); model.navigate(.home)
    }
    // This settings/navigation suite uses only its own folder. The full suite
    // continues to initialize and verify the real selected NAS source.
    model.mediaRoot = output.path
    func waitFolders() async {
      for _ in 0..<120 { if !model.localFolders.loading { break }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    checks["sourceActionsHaveOneParentAndAutomaticRecognitionIsNotASetting"] = !TVSetting.groups.flatMap { $0 }.contains(.addFolder) && !TVSetting.groups.flatMap { $0 }.contains(.nas) && !TVSetting.groups.flatMap { $0 }.contains(.metadata)
    checks["navigationRejectsUnknownDuplicatesAndKeepsHomeSettings"] = TVNavigationTab.normalized(["quark", "quark", "unknown"]) == [.home, .quark, .settings]
    checks["navigationContainsOnlyContentTabs"] = model.navigationItemCount == model.visibleNavigationTabs.count
    checks["settingsHaveExactlyThreeCategories"] = TVSetting.groups.count == 3
    let savedTabs = UserDefaults.standard.stringArray(forKey: "mtv.navigation.tabs")
    model.navigate(.settings); model.performSetting(.navigation)
    model.navigationCustomizationIndex = 2; model.handle(.select)
    checks["navigationCanAddQuarkWithoutInstallingAnotherApp"] = model.navigationTabs.contains(.quark)
      && model.visibleNavigationTabs.contains(.quark) && model.focus.rows[0] == 6
    await settle(); capture(window, to: output.appendingPathComponent("navigation-customization.png"))
    model.handle(.back)
    checks["navigationCustomizationBackReturnsToSettings"] = !model.navigationCustomizationVisible && model.section == .settings
    model.navigate(.settings); model.settingsGroup = 1; model.handle(.down); model.handle(.up)
    checks["settingsUpReturnsToItsActualCustomizedTabIndex"] = model.focus.row == 0 && model.focus.column == 5 && model.section == .settings
    model.performSetting(.navigation)
    for index in [0, 1, 3] { model.navigationCustomizationIndex = index; model.handle(.select) }
    checks["navigationCanHideMultipleEntriesAndUpdatesFocusRows"] = model.visibleNavigationTabs == [.home, .quark, .settings] && model.focus.rows[0] == 3
    model.setNavigationTab(.home, enabled: false); model.setNavigationTab(.settings, enabled: false)
    checks["navigationAlwaysKeepsHomeAndSettingsReachable"] = model.visibleNavigationTabs.first == .home && model.visibleNavigationTabs.last == .settings
    model.handle(.back); model.navigate(.settings); model.settingsGroup = 1; model.handle(.down); model.handle(.up)
    checks["navigationRemovedTabsDoNotLeaveDeadFocusColumns"] = model.focus.row == 0 && model.focus.column == model.visibleNavigationTabs.firstIndex(of: .settings)
    checks["navigationSmokeDoesNotWriteNormalPreferences"] = UserDefaults.standard.stringArray(forKey: "mtv.navigation.tabs") == savedTabs
    model.navigationTabs = originalTabs
    model.navigate(.settings); model.settingsSidebarFocus = true; model.settingsGroup = 1
    model.focus.select(row: 0, column: 4); model.handle(.down)
    checks["settingsDownEntersCategorySidebar"] = model.settingsSidebarFocus && model.focus.row == 1
    model.handle(.down); model.handle(.right)
    checks["settingsRightEntersOptionsList"] = model.settingsGroup == 2 && !model.settingsSidebarFocus && model.focus.column == 0
    model.handle(.down)
    checks["settingsGeneralOptionsReachFullscreen"] =
      TVSetting.visibleSetting(row: model.focus.row, column: model.focus.column) == .fullscreen
      && !TVSetting.groups[1].contains(.engine) && !TVSetting.groups[1].contains(.metadata)
    model.handle(.left)
    checks["settingsLeftReturnsToCategory"] = model.settingsSidebarFocus && model.settingsGroup == 2
    for value in TVAppearance.allCases {
      model.setAppearance(value)
      for group in 1...TVSetting.groups.count {
        model.settingsGroup = group; model.focus.select(row: group, column: 0); model.settingsSidebarFocus = false
        await settle(); capture(window, to: output.appendingPathComponent("settings-\(value.rawValue)-\(group).png"))
      }
    }
    model.performSetting(.appearance)
    checks["appearanceIsReachableFromSettings"] = model.appearanceVisible
    model.appearanceSelection = 2; model.handle(.select)
    checks["lightThemeAppliesWithoutClosingPanel"] = model.appearance == .light && model.appearanceVisible
    model.appearanceSelection = 4; model.handle(.select)
    checks["glassCanBeDisabledIndependently"] = !model.glassEnabled && model.appearance == .light
    await settle(); capture(window, to: output.appendingPathComponent("appearance-light-solid.png"))
    model.handle(.back)
    checks["appearanceBackReturnsToSelectedSetting"] = !model.appearanceVisible && model.section == .settings && model.focus.row == TVSetting.appearance.row
    for nas in [false, true] {
      await openSettingWithRemote(.sources, model: model)
      for _ in 0..<120 { if !model.savedSources.loading { break }; try? await Task.sleep(for: .milliseconds(50)) }
      model.savedSources.selection = model.savedSources.sources.count + (nas ? 1 : 0)
      model.savedSources.activate()
      if !nas { await waitFolders() }
      else { for _ in 0..<120 { if !model.smb.profilesLoading { break }; try? await Task.sleep(for: .milliseconds(50)) } }
      checks["sourceListOpensChildEditor-\(nas)"] = !model.savedSources.isPresented && (nas ? model.smb.isPresented : model.localFolders.isPresented)
      model.handle(.back)
      checks["sourceEditorBackRestoresSourceList-\(nas)"] = model.savedSources.isPresented && !model.smb.isPresented && !model.localFolders.isPresented
      model.handle(.back)
      checks["sourceListSecondBackReturnsToSettings-\(nas)"] = !model.savedSources.isPresented && model.section == .settings
    }
    for setting in [TVSetting.sources, .audio, .accounts, .nas, .addFolder, .plugins, .about, .history] {
      await openSettingWithRemote(setting, model: model)
      if setting == .addFolder { await waitFolders() }
      if setting == .nas { model.smb.back() } else { model.handle(.back) }
      // Child editors return to Sources, then the next Back returns to Settings.
      if model.smb.isPresented { model.handle(.back) }
      if model.savedSources.isPresented { model.handle(.back) }
      checks["returnFromSetting-\(setting.rawValue)"] = model.section == .settings
        && !model.sourceSetup.isPresented && !model.localFolders.isPresented && !model.enginePickerVisible
        && !model.audioOutputVisible && !model.accountSettingsVisible && !model.setupGuideVisible
        && !model.savedSources.isPresented && !model.pluginManager.isPresented && !model.automaticMetadata.isPresented
        && !model.continueWatching.recoveryPresented && !model.smb.isPresented
    }
    model.accountSettingsVisible = true
    if let plugin = model.plugins.first(where: { $0.id == "mtv.quark" }) {
      model.login.presentFixture(plugin); model.handle(.back)
      checks["loginBackRestoresAccountsParent"] = !model.login.isPresented && model.accountSettingsVisible
      model.handle(.back)
      checks["accountsSecondBackReturnsToSettings"] = !model.accountSettingsVisible && model.section == .settings
    }
    model.playbackVolumeVisible = true; model.notice = "测试提示"; model.handle(.back)
    checks["backDismissesNoticeBeforeUnderlyingVolumeMenu"] = model.notice == nil && model.playbackVolumeVisible
    model.handle(.back)
    checks["nextBackDismissesUnderlyingVolumeMenu"] = !model.playbackVolumeVisible
    let item = MediaItem(id: "tv-refinement-metadata", title: "测试影片")
    model.metadata.present(item, search: false); model.showMetadataQuery()
    model.handle(.text("不应保存")); model.handle(.back)
    checks["keyboardBackReturnsToMetadataWithoutApplyingDraft"] = !model.keyboardVisible && model.metadata.isPresented && model.metadata.query == item.title
    model.handle(.back)
    checks["metadataBackClosesToSettings"] = !model.metadata.isPresented && model.section == .settings
    do {
      let root = output.appendingPathComponent("FolderReturn"), child = root.appendingPathComponent("Child")
      try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
      model.localFolders.present(at: root); await waitFolders()
      model.localFolders.browse(child); await waitFolders(); model.handle(.back); await waitFolders()
      let folderObservation: [String: Any] = ["expected": root.path, "actual": model.localFolders.directory?.path ?? "",
        "presented": model.localFolders.isPresented, "message": model.localFolders.message]
      if let data = try? JSONSerialization.data(withJSONObject: folderObservation, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("folder-return.json"))
      }
      checks["folderBackReturnsToPreviousDirectory"] = model.localFolders.isPresented && model.localFolders.directory?.path == root.path
      model.handle(.back)
      checks["folderRootBackReturnsToSettings"] = !model.localFolders.isPresented && model.section == .settings
    } catch { checks["folderReturnFixtureCreated"] = false }
    model.setAppearance(.dark); model.setGlass(true); model.performSetting(.appearance)
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); await settle()
    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) {
      let active = NSApp.isActive && window.isKeyWindow
      NSApp.postEvent(event, atStart: false); await settle()
      checks["nativeEscapeReturnsFromAppearanceOrIgnoresInactiveWindow"] = active ? !model.appearanceVisible : model.appearanceVisible
    } else { checks["nativeEscapeCreated"] = false }
    checks["testDoesNotWriteNormalThemePreferences"] = (UserDefaults.standard.object(forKey: "mtv.appearance") as? String) == savedAppearance
    return checks
  }
}

import Foundation

extension AppModel {
  func sourceEditorCancelled() {
    if sourceEditorReturnsToSavedSources {
      sourceEditorReturnsToSavedSources = false; presentSavedSources()
    } else if sourceNeedsSetup { presentSourceSetup() }
  }
  /// Keep this order in sync with the overlays in RootView/MPVPlaybackOverlay.
  /// Back removes one visible layer; it never doubles as Home or a setting change.
  func returnFromTopmostMenu() -> Bool {
    if notice != nil { notice = nil; return true }
    if mediaSessionConsent != nil { mediaSessionConsent = nil; return true }
    if continueWatching.recoveryPresented { continueWatching.closeRecovery(); return true }
    if watchlist.menuID != nil { watchlist.menuID = nil; return true }
    if continueWatching.menuID != nil { continueWatching.menuID = nil; return true }
    if checkingModuleContinuation { cancelCheckingModuleContinuation(); return true }
    if episodeChoices != nil { dismissEpisodeChoices(); return true }
    if playbackTracks.isPresented { playbackTracks.close(); return true }
    if videoPresentation.isPresented { videoPresentation.close(); return true }
    if navigationCustomizationVisible { navigationCustomizationVisible = false; return true }
    if appearanceVisible { appearanceVisible = false; return true }
    if libraryBrowser.isPresented { libraryBrowser.close(); return true }
    if audioOutputVisible { audioOutputVisible = false; return true }
    if enginePickerVisible { enginePickerVisible = false; return true }
    if login.isPresented { login.back(); return true }
    if accountSettingsVisible { accountSettingsVisible = false; return true }
    if keyboardVisible { finishTextEntry(commit: false); return true }
    if metadata.isPresented { metadata.close(); return true }
    if automaticMetadata.isPresented {
      automaticMetadata.close()
      return true
    }
    if pluginFolders.isPresented { pluginFolders.back(); return true }
    if pluginManager.isPresented { pluginManager.back(); return true }
    if localFolders.isPresented { localFolders.back(); return true }
    if smb.isPresented { smb.back(); return true }
    if libraryOverview.isPresented { libraryOverview.back(); return true }
    if savedSources.isPresented { savedSources.back(); return true }
    if sourceSetup.isPresented { sourceSetup.close(); return true }
    if setupGuideVisible {
      if setupGuideStep > 0 { setupGuideStep -= 1; setupGuideSelection = 0 }
      else { finishSetupGuide(completed: false) }
      return true
    }
    if playbackVolumeVisible { playbackVolumeVisible = false; showPlayerControls(); return true }
    if playbackSpeedVisible { playbackSpeedVisible = false; showPlayerControls(); return true }
    return false
  }
  func moveSettingsFocus(dx: Int, dy: Int) {
    if settingsSidebarFocus {
      if dy < 0, settingsGroup == 1 { focus.select(row: 0, column: visibleNavigationTabs.firstIndex(of: .settings) ?? 0); return }
      settingsGroup = min(TVSetting.groups.count, max(1, settingsGroup + dy))
      focus.select(row: settingsGroup, column: 0)
      if dx > 0 { settingsSidebarFocus = false }
    } else {
      if dx < 0 { settingsSidebarFocus = true; focus.select(row: settingsGroup, column: 0) }
      else {
        let count = TVSetting.groups[settingsGroup - 1].count
        focus.select(row: settingsGroup, column: min(count - 1, max(0, focus.column + dy)))
      }
    }
  }
}

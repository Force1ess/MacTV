import AppKit
import AVFoundation
import MTVCore
import SQLite3

extension UISmoke {
  static func tvExperienceSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    let oldEngine = model.preferredEngine
    defer { model.stopPlayback(); model.playbackRate = 1; model.preferredEngine = oldEngine; model.notice = nil; model.navigate(.home) }
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<400 { if condition() { return }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    model.navigate(.home); model.handle(.right)
    checks["tvTabSwitchesOnFocusWithoutConfirm"] = model.section == .library && model.focus.row == 0 && model.focus.column == 1
    model.search = "keep-current-page"; model.handle(.select)
    checks["tvTabConfirmDoesNotReloadCurrentPage"] = model.search == "keep-current-page"
    model.search = ""; model.focus.select(row: 1, column: 2); model.handle(.up)
    checks["tvUpEntersCurrentTabInsteadOfCardColumn"] = model.section == .library && model.focus.column == 1
    model.focusNavigation(at: 4)
    checks["tvPointerTabUsesSameImmediateNavigation"] = model.section == .settings
    await settle(); capture(window, to: output.appendingPathComponent("settings.png"))
    model.performSetting(.sources); await wait { !model.savedSources.loading }
    model.handle(.back)
    checks["tvSourcesBackClosesToSettings"] = !model.savedSources.isPresented && model.section == .settings
    checks["tvEngineSelectionIsNotInUserSettings"] = !TVSetting.groups.flatMap { $0 }.contains(.engine)
    model.performSetting(.audio); model.handle(.back)
    checks["tvAudioBackClosesToSettings"] = !model.audioOutputVisible && model.section == .settings
    model.performSetting(.accounts); model.handle(.back)
    checks["tvAccountsBackClosesToSettings"] = !model.accountSettingsVisible && model.section == .settings
    model.localFolders.present(at: output); await wait { !model.localFolders.loading }
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    await settle()
    let canReceiveKey = NSApp.isActive && window.isKeyWindow
    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51) {
      NSApp.postEvent(event, atStart: false); await settle()
      if canReceiveKey {
        checks["tvNativeDeleteBackKeyClosesFolderPanel"] = !model.localFolders.isPresented && model.section == .settings
      } else {
        checks["tvInactiveWindowDoesNotConsumeBackspace"] = model.localFolders.isPresented
      }
    } else { checks["tvNativeDeleteBackKeyClosesFolderPanel"] = false }
    let keyEvidence: [String: Any] = ["activeAndKeyWindow": canReceiveKey, "route": model.smokeKeyRoute,
      "physicalRemoteVerified": false, "activeWindowBackKeyVerified": canReceiveKey && !model.localFolders.isPresented]
    if let data = try? JSONSerialization.data(withJSONObject: keyEvidence, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("back-key-window.json"))
    }
    model.localFolders.close()
    checks["tvBilibiliBrandIconIsPackaged"] = BrandIcon.image("mtv.bilibili") != nil
    checks["tvQuarkBrandIconIsPackaged"] = BrandIcon.image("mtv.quark") != nil
    model.navigate(.library)
    if let series = model.visibleItems.first(where: { $0.kind == .series }) {
      model.activateCard(series)
      checks["tvSeriesOpensEpisodesWithoutSeasonDirectory"] = model.libraryPath.count == 1 && !model.visibleItems.isEmpty
        && model.visibleItems.allSatisfy { !$0.isLibraryCollection }
      checks["tvFlattenedEpisodesKeepSeasonAndEpisodeLabels"] = model.visibleItems.allSatisfy {
        $0.localMetadata?.episode == nil || $0.subtitle.range(of: #"^S[0-9]+E[0-9]+$"#, options: .regularExpression) != nil
      }
      await settle(); capture(window, to: output.appendingPathComponent("series-episodes.png"))
    } else { checks["tvSeriesFixtureAvailable"] = false }
    if let bili = model.plugins.first(where: { $0.id == "mtv.bilibili" }), CommandLine.arguments.contains("--live-services") {
      model.moduleSessionAccess = .guest; model.openModule(bili); await wait { !model.loading }
      checks["tvBilibiliDefaultsToCenteredHome"] = model.bilibiliChannel == .home && BilibiliChannel.allCases[2] == .home
      checks["tvBilibiliActualHomepageLoads"] = !model.online.isEmpty && model.moduleLoadFailure == nil
      if let failure = model.moduleLoadFailure { try? Data(failure.message.utf8).write(to: output.appendingPathComponent("homepage-error.txt")) }
      model.focus.select(row: 1, column: 2)
      model.handle(.down)
      checks["tvBilibiliHomeDownEntersSearch"] = model.focus.row == model.moduleToolbarRow && model.focus.column == 0
      model.handle(.up)
      checks["tvBilibiliSearchUpRestoresCurrentChannel"] = model.focus.row == 1 && model.focus.column == 2
      await settle()
      capture(window, to: output.appendingPathComponent("bilibili-home.png"))
      model.handle(.left); await wait { !model.loading }
      checks["tvBilibiliRankingSwitchesWithoutConfirm"] = model.bilibiliChannel == .ranking && !model.online.isEmpty && model.moduleLoadFailure == nil
      let ranking: [String: Any] = ["section": model.section.rawValue, "channel": model.bilibiliChannel.rawValue,
        "focusRow": model.focus.row, "focusColumn": model.focus.column, "items": model.online.count,
        "failure": model.moduleLoadFailure?.message ?? "", "loading": model.loading,
        "notice": model.notice ?? ""]
      if let data = try? JSONSerialization.data(withJSONObject: ranking, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ranking-observation.json"))
      }
      model.selectBilibiliChannel(at: 0); await wait { !model.loading }
      checks["tvBilibiliPopularStillLoads"] = model.bilibiliChannel == .popular && !model.online.isEmpty && model.moduleLoadFailure == nil
      let beforeMore = Set(model.online.map(\.id))
      if model.moduleNextPage != nil {
        model.focus.select(row: max(model.mediaFocusOffset, model.mediaFocusOffset + model.mediaRows.count - 2), column: 0)
        model.handle(.down); await wait { !model.loading }
        checks["tvBilibiliRemoteNearBottomLoadsWithoutConfirm"] = model.moduleLoadFailure == nil && Set(model.online.map(\.id)).count > beforeMore.count
      } else { checks["tvBilibiliPaginationCursorAvailable"] = false }
      model.selectBilibiliChannel(at: 3); await wait { !model.loading }
      checks["tvBilibiliDynamicHasExplicitGuestLoginState"] = model.moduleNeedsLogin && model.moduleLoadFailure == nil
      model.selectBilibiliChannel(at: 4); await wait { !model.loading }
      checks["tvBilibiliFavoritesHasExplicitGuestLoginState"] = model.moduleNeedsLogin && model.moduleLoadFailure == nil
    }
    model.navigate(.home); model.preferredEngine = .system
    let fixture = SystemAudioWaveSource.ownedFixtureURL
    let item = MediaItem(id: "tv-experience-own-fixture", title: "播放体验验证", subtitle: "自建片源", overview: "简介显示在播放控制上方。", url: fixture.absoluteString)
    model.activateCard(item)
    await wait { model.testDecodedFrame() != nil || model.notice != nil }
    checks["tvVideoCardStartsActualPlaybackWithoutDetail"] = model.detail == nil && model.player != nil && model.testDecodedFrame() != nil
    model.playerCommand(8)
    checks["tvPlaybackSpeedIsRemoteReachable"] = model.playbackSpeedVisible
    model.playbackSpeedIndex = 6; model.handle(.select)
    await settle()
    checks["tvSystemPlayerAppliesActualDoubleSpeed"] = !model.playbackSpeedVisible && model.player?.rate == 2 && model.playbackRate == 2
    model.playerCommand(1); model.applyPlaybackRate(0.75)
    checks["tvChangingSpeedWhilePausedKeepsPause"] = model.paused && model.player?.rate == 0 && model.player?.defaultRate == 0.75
    model.playerCommand(1); await settle()
    checks["tvResumeKeepsChosenSpeed"] = model.player?.rate == 0.75
    model.setPlaybackVolume(0.4)
    checks["tvSystemPlayerAppliesActualVolume"] = model.player?.volume == 0.4 && model.playbackVolume == 0.4
    model.togglePlaybackMute()
    checks["tvMuteSetsSoftwareVolumeToZero"] = model.player?.volume == 0
    model.togglePlaybackMute()
    checks["tvUnmuteRestoresPreviousVolume"] = model.player?.volume == 0.4
    model.playerCommand(9); model.handle(.down)
    checks["tvVolumeRemoteAdjustsWithoutStoppingPlayback"] = model.playbackVolumeVisible && abs((model.player?.volume ?? 0) - 0.35) < 0.001
    model.handle(.back)
    checks["tvVolumeBackReturnsToPlayback"] = !model.playbackVolumeVisible && model.playbackPresented
    capture(window, to: output.appendingPathComponent("player-introduction.png"))
    model.stopPlayback(); model.playbackRate = 1; model.preferredEngine = .vlc
    model.activateCard(item); await wait { (model.vlcEngine?.latest?.displayedPictures ?? 0) > 0 || model.notice != nil }
    if let engine = model.vlcEngine {
      model.applyPlaybackRate(1.5); await settle()
      checks["tvVLCPlayerConfirmsNativeSpeed"] = abs(await engine.currentRate() - 1.5) < 0.01 && model.playbackRate == 1.5
      model.setPlaybackVolume(0.3); await settle()
      let audio = await engine.audioOutputStatus()
      checks["tvVLCPlayerConfirmsNativeVolume"] = audio["volume"] == "30" && model.playbackVolume == 0.3
      engine.setAudioOutput(nil); await settle()
      checks["tvChangingOutputPreservesVolume"] = await engine.audioOutputStatus()["volume"] == "30"
      model.stopPlayback(); await engine.waitUntilStopped()
    } else { checks["tvVLCPlayerConfirmsNativeSpeed"] = false }
    do {
      let file = output.appendingPathComponent("chrome-fake-cookies.sqlite")
      var database: OpaquePointer?
      guard sqlite3_open(file.path, &database) == SQLITE_OK, let database else { throw CocoaError(.fileWriteUnknown) }
      defer { sqlite3_close(database) }
      let sql = "CREATE TABLE meta(key TEXT,value INTEGER); INSERT INTO meta VALUES('version',24); CREATE TABLE cookies(host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,path TEXT,expires_utc INTEGER); INSERT INTO cookies VALUES('.quark.cn','__puus','fake-owned-test-session',X'','/',0); INSERT INTO cookies VALUES('.unrelated.invalid','__puus','',X'010203','/',0);"
      guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
      let imported = try LocalChromeQuark.readDatabase(file)
      checks["tvChromeSQLiteReaderFiltersOtherSitesBeforeDecrypt"] = imported.cookie == "__puus=fake-owned-test-session"
      sqlite3_exec(database, "UPDATE cookies SET expires_utc=1 WHERE host_key='.quark.cn'", nil, nil, nil)
      do { _ = try LocalChromeQuark.readDatabase(file); checks["tvChromeSQLiteReaderRejectsExpiredSession"] = false }
      catch { checks["tvChromeSQLiteReaderRejectsExpiredSession"] = true }
    } catch { checks["tvChromeSQLiteFixtureFlow"] = false }
    return checks
  }
}

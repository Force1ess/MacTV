import AppKit
import MTVCore
import SQLite3

extension UISmoke {
  static func chromeLoginSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    do {
      let operation = ChromeStorageReadOperation(), child = Process()
      child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["10"]
      child.standardInput = FileHandle.nullDevice; child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
      try operation.start(child)
      checks["chromeReaderOwnedChildActuallyStarted"] = child.isRunning
      let started = ProcessInfo.processInfo.systemUptime
      operation.cancel(); child.waitUntilExit(); operation.finish(child)
      checks["chromeReaderCancellationTerminatesOwnedChildPromptly"] = !child.isRunning && operation.isCancelled
        && ProcessInfo.processInfo.systemUptime - started < 2
      let late = Process(); late.executableURL = URL(fileURLWithPath: "/bin/sleep"); late.arguments = ["10"]
      do { try operation.start(late); checks["chromeReaderCancelledAttemptCannotSpawnLateChild"] = false; late.terminate(); late.waitUntilExit() }
      catch { checks["chromeReaderCancelledAttemptCannotSpawnLateChild"] = !late.isRunning }
    } catch { checks["chromeReaderOwnedCancellationFixture"] = false }
    let appearance = model.appearance
    defer { model.appearance = appearance; model.login.close(reload: false); model.notice = nil; model.navigate(.home) }
    do {
      let directory = output.appendingPathComponent("owned-chrome-root/Default")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      var reads = 0
      let read: () async throws -> [LocalChromeQuark.Profile] = {
        reads += 1
        _ = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        return [.init(directory: directory, title: "Owned Chrome fixture")]
      }
      let discovered = try await ChromeProfileDiscovery.load(restore: { throw CocoaError(.fileReadCorruptFile) }, read: read)
      checks["staleSavedGrantDoesNotHideCurrentDirectoryAccess"] = discovered.profiles.count == 1
        && discovered.savedAccessWarning?.code == CocoaError.fileReadCorruptFile.rawValue && reads == 1
      do {
        _ = try await ChromeProfileDiscovery.load(restore: { throw CocoaError(.fileReadCorruptFile) }, read: { throw CocoaError(.fileReadNoPermission) })
        checks["currentDirectoryPermissionDenialStillStopsDiscovery"] = false
      } catch {
        checks["currentDirectoryPermissionDenialStillStopsDiscovery"] = (error as NSError).domain == NSCocoaErrorDomain
          && (error as NSError).code == CocoaError.fileReadNoPermission.rawValue
      }
      let normal = try await ChromeProfileDiscovery.load(restore: {}, read: read)
      checks["currentDirectoryDiscoveryDoesNotNeedStoredBookmark"] = normal.savedAccessWarning == nil && normal.profiles.count == 1
      checks["missingDirectoryIsNotMisreportedAsPrivacyDenial"] = ChromeProfileDiscovery.message(for: CocoaError(.fileNoSuchFile)).contains("还没有Chrome资料")
      checks["technicalErrorCodesStayOutOfLoginCopy"] = !ChromeProfileDiscovery.message(for: NSError(domain: "OWNED_TEST_DOMAIN", code: 257)).contains("OWNED_TEST_DOMAIN")
    } catch { checks["ownedDirectoryDiscoveryFixture"] = false }
    checks["chromeFolderPermissionOnlyAcceptsExpectedLocalFolder"] = ChromeFolderAccess.isExpectedFolder(LocalChromeQuark.chromeRoot)
      && !ChromeFolderAccess.isExpectedFolder(FileManager.default.homeDirectoryForCurrentUser)
      && !ChromeFolderAccess.isExpectedFolder(URL(string: "https://example.invalid/Chrome")!)
    do {
      let file = output.appendingPathComponent("owned-chrome.sqlite")
      var connection: OpaquePointer?
      guard sqlite3_open(file.path, &connection) == SQLITE_OK, let connection else { throw CocoaError(.fileWriteUnknown) }
      defer { sqlite3_close(connection) }
      let schema = "CREATE TABLE meta(key TEXT,value INTEGER); INSERT INTO meta VALUES('version',24); CREATE TABLE cookies(host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,path TEXT,expires_utc INTEGER);"
      guard sqlite3_exec(connection, schema, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
      var unlocks = 0
      let unlock: () throws -> Data = { unlocks += 1; throw CocoaError(.userCancelled) }
      // No main login cookie: unrelated encrypted fields must not cause Keychain access.
      sqlite3_exec(connection, "INSERT INTO cookies VALUES('.quark.cn','__uid','',X'763230010203','/',0);", nil, nil, nil)
      do { _ = try LocalChromeQuark.readDatabase(file, unlock: unlock); checks["missingQuarkLoginRejectedBeforeUnlock"] = false }
      catch {
        // The reason identity is separate from its localized presentation.
        if case MTVError.message(let reason) = error {
          checks["missingQuarkLoginRejectedBeforeUnlock"] = unlocks == 0 && reason.contains("没有有效")
        } else { checks["missingQuarkLoginRejectedBeforeUnlock"] = false }
      }
      sqlite3_exec(connection, "INSERT INTO cookies VALUES('.bilibili.com','SESSDATA','',X'763130010203','/',1);", nil, nil, nil)
      do { _ = try LocalChromeQuark.readDatabase(file, provider: "mtv.bilibili", unlock: unlock); checks["expiredBilibiliRejectedBeforeUnlock"] = false }
      catch { checks["expiredBilibiliRejectedBeforeUnlock"] = unlocks == 0 }
      sqlite3_exec(connection, "UPDATE cookies SET value='OWNED-FAKE-SESSION', encrypted_value=X'',expires_utc=0 WHERE name='SESSDATA';", nil, nil, nil)
      let session = try LocalChromeQuark.readDatabase(file, provider: "mtv.bilibili", unlock: unlock)
      checks["sqliteBilibiliImportExcludesQuarkSecrets"] = session.pluginID == "mtv.bilibili" && session.cookie == "SESSDATA=OWNED-FAKE-SESSION" && unlocks == 0
      checks["sqliteBilibiliSessionCannotReachQuarkOrCDN"] = session.cookieHeader(for: URL(string: "https://drive.quark.cn/")!) == nil
        && session.cookieHeader(for: URL(string: "https://video.bilivideo.com/")!) == nil
      sqlite3_exec(connection, "UPDATE cookies SET value='', encrypted_value=X'763130010203' WHERE name='SESSDATA';", nil, nil, nil)
      do { _ = try LocalChromeQuark.readDatabase(file, provider: "mtv.bilibili", unlock: unlock); checks["encryptedBilibiliRequestsExplicitUnlock"] = false }
      catch { checks["encryptedBilibiliRequestsExplicitUnlock"] = unlocks == 1 }
    } catch { checks["chromeSQLiteFixtureCompleted"] = false }
    for appearance in [TVAppearance.dark, .light] {
      model.setAppearance(appearance)
      for identifier in ["mtv.quark", "mtv.bilibili"] {
      let caseID = identifier + "-" + appearance.rawValue
      guard let plugin = model.plugins.first(where: { $0.id == identifier }) else { checks["platformPackaged-" + caseID] = false; continue }
      model.login.presentFixture(plugin)
      model.login.state = "chromeAuthorization"; model.login.selectedButton = 0
      model.login.activate(allowChromeImport: true, allowInteraction: false)
      checks["authorizationNeedsExplicitInteractiveAction-" + caseID] = model.login.controlRejection == "requires-interactive-action"
        && model.login.state == "chromeAuthorization"
      model.handle(.back)
      checks["authorizationBackReturnsOneLevel-" + caseID] = model.login.isPresented && model.login.state == "waiting"
      await settle(); capture(window, to: output.appendingPathComponent(caseID + "-qr.png"))
      checks["chromeButton-" + caseID] = model.login.buttons.contains("从Chrome导入")
      model.login.beginLocalChromeImport()
      for _ in 0..<120 { if model.login.state != "loading" { break }; try? await Task.sleep(for: .milliseconds(50)) }
      checks["chromeChoicePageDoesNotAutoReadCookies-" + caseID] = model.login.state == "chromeProfiles"
      if !model.login.availableChromeProfileTitles.isEmpty {
        checks["translatedChromeControlsPreserveUserProfileNames-" + caseID] =
          Array(model.login.displayedButtonTitles.prefix(model.login.availableChromeProfileTitles.count)) == model.login.availableChromeProfileTitles
      }
      checks["chromePermissionFailureKeepsUsableAlternative-" + caseID] = !model.login.chromeProfilesUnavailable
        || ((model.login.message.contains("授权") || model.login.message.contains("系统设置")) && model.login.buttons.contains("通过Chrome扩展导入"))
      checks["chromeExtensionAndBrowserEntryReachable-" + caseID] = model.login.buttons.contains("通过Chrome扩展导入") && model.login.buttons.contains("在Chrome登录")
      checks["chromeFolderPermissionEntryReachable-" + caseID] = model.login.buttons.contains("打开访问授权")
      let observation: [String: Any] = ["platform": identifier, "metadataDirectoryReadable": !model.login.chromeProfilesUnavailable,
        "state": model.login.state, "message": model.login.message, "realCookiesRead": false, "realLoginVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: observation, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent(caseID + "-chrome-observation.json"))
      }
      model.login.selectedButton = 0; model.handle(.down)
      checks["chromeProfileRemoteDownMovesSelection-" + caseID] = model.login.selectedButton == 1
      await settle(); capture(window, to: output.appendingPathComponent(caseID + "-chrome.png"))
      model.handle(.back)
      checks["chromeProfileBackReturnsToPlatformLogin-" + caseID] = model.login.isPresented && model.login.state == "waiting"
      model.handle(.back)
      checks["platformLoginNextBackCloses-" + caseID] = !model.login.isPresented
    }
    }
    return checks
  }
}

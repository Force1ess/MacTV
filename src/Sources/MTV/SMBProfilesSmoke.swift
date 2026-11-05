import AppKit
import MTVCore

extension UISmoke {
  static func smbProfilesSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String:
    Bool]
  {
    let controller = model.smb
    let oldStore = controller.profileStore
    let oldVault = controller.credentialStore
    let file = output.appendingPathComponent("smb-profiles/connections.json")
    let service = "local.mtv.preview.smb-ui-fixture." + UUID().uuidString
    let vault = SMBCredentialStore(service: service)
    var createdCredential: UUID?
    defer {
      if let id = createdCredential { try? vault.remove(profileID: id) }
      controller.close()
      controller.profileStore = oldStore
      controller.credentialStore = oldVault
      controller.connectionObserverForTesting = nil
      model.navigate(.home)
    }
    var checks: [String: Bool] = [:]
    func waitForList() async {
      for _ in 0..<150 {
        if !controller.profilesLoading { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
    func choose(_ control: SMBControl) {
      guard let index = controller.controls.firstIndex(of: control) else { return }
      controller.selection = index
      model.handle(.select)
    }
    do {
      controller.profileStore = SMBProfileStore(file: file)
      controller.credentialStore = vault
      controller.present()
      await waitForList()
      controller.address = "smb://fixture.invalid/Movies/TV"
      controller.username = ""
      controller.guest = true
      choose(.saveProfile)
      await controller.waitForPendingSaves()
      let saved = try await SMBProfileStore(file: file).load()
      checks["smbGuestProfileSavedWithoutNetwork"] =
        saved.count == 1 && saved[0].guest
        && !saved[0].rememberPassword && controller.phase == "form"
      controller.close()
      controller.present()
      await waitForList()
      checks["smbProfilesReopenAsSavedList"] =
        controller.phase == "profiles" && controller.profiles.count == 1
      await settle()
      capture(window, to: output.appendingPathComponent("29-smb-saved-profiles.png"))
      if let profile = saved.first {
        choose(.profile(profile.id))
        checks["smbSavedProfileRestoresFieldsAndConnectFocus"] =
          controller.address == profile.address
          && controller.guest && controller.password.isEmpty
          && controller.controls[controller.selection] == .connect
        var reconnectObserved = false
        controller.connectionObserverForTesting = { location, user, password, guest in
          reconnectObserved =
            location.shareURL.host == "fixture.invalid"
            && location.subdirectory == ["TV"] && user.isEmpty && password.isEmpty && guest
        }
        choose(.connect)
        for _ in 0..<100 {
          if controller.phase != "connecting" { break }
          try? await Task.sleep(for: .milliseconds(50))
        }
        checks["smbSavedGuestReconnectParameters"] = reconnectObserved
        var rootRequested = false
        controller.connectionObserverForTesting = { location, user, password, guest in
          rootRequested = location.shareURL.host == "fixture.invalid" && location.subdirectory.isEmpty
            && user.isEmpty && password.isEmpty && guest
        }
        choose(.connectRoot)
        for _ in 0..<100 {
          if controller.phase != "connecting" { break }
          try? await Task.sleep(for: .milliseconds(50))
        }
        let retainedSelection = try await controller.profileStore.load().first?.address
        checks["smbExplicitRootRecoveryKeepsSavedSelectionUntilConfirmed"] = rootRequested
          && retainedSelection == "smb://fixture.invalid/Movies/TV"
        choose(.deleteProfile)
        checks["smbDeleteDefaultsToCancel"] =
          controller.phase == "confirmDelete" && controller.selection == 1
        model.handle(.back)
        checks["smbDeleteBackKeepsProfile"] = try await controller.profileStore.load().count == 1
        choose(.deleteProfile)
        choose(.confirmDelete)
        await controller.waitForPendingSaves()
        checks["smbConfirmedDeleteRemovesOnlySelectedRecord"] = try await controller.profileStore
          .load().isEmpty
      }
      if CommandLine.arguments.contains("--test-keychain") {
        controller.newConnection()
        controller.address = "smb://fixture.invalid/Movies"
        controller.username = "MTV_FIXTURE_ACCOUNT"
        controller.password = "MTV_SMB_KEYCHAIN_TEST_ONLY_12345"
        controller.rememberPassword = true
        choose(.saveProfile)
        await controller.waitForPendingSaves()
        guard let profile = controller.profiles.first else { throw MTVError.message("钥匙串测试连接未保存") }
        createdCredential = profile.id
        let cold = try await Task.detached {
          try SMBCredentialStore(service: service).load(for: profile)
        }.value
        checks["smbOwnKeychainCredentialColdRoundtrip"] =
          cold == "MTV_SMB_KEYCHAIN_TEST_ONLY_12345"
          && controller.password.isEmpty && controller.storedPasswordAvailable
        await settle()
        capture(window, to: output.appendingPathComponent("30-smb-reconnect-form.png"))
        let bytes = try Data(contentsOf: file)
        checks["smbMetadataNeverContainsPassword"] = !String(decoding: bytes, as: UTF8.self)
          .contains("MTV_SMB_KEYCHAIN_TEST_ONLY")
        var observed = 0
        controller.connectionObserverForTesting = { location, user, password, guest in
          if location.shareURL.host == "fixture.invalid", user == "MTV_FIXTURE_ACCOUNT",
            password == "MTV_SMB_KEYCHAIN_TEST_ONLY_12345", !guest
          {
            observed += 1
          }
        }
        choose(.connect)
        for _ in 0..<100 {
          if controller.phase != "connecting" { break }
          try? await Task.sleep(for: .milliseconds(50))
        }
        checks["smbSavedAccountReconnectUsesScopedCredential"] = observed == 1
        controller.address = "smb://other.invalid/Movies"
        controller.connect()
        for _ in 0..<100 {
          if controller.phase != "connecting" { break }
          try? await Task.sleep(for: .milliseconds(50))
        }
        checks["smbEditedHostCannotReuseSavedPassword"] =
          observed == 1 && controller.phase == "form"
          && controller.message.contains("重新输入密码")
        controller.selectProfile(profile.id)
        choose(.deleteProfile)
        choose(.confirmDelete)
        await controller.waitForPendingSaves()
        let removed = await Task.detached { (try? vault.load(for: profile)) == nil }.value
        checks["smbDeletingOwnProfileRemovesCredential"] = removed && controller.profiles.isEmpty
      }
    } catch { checks["smbProfilesFixtureFlow"] = false }
    return checks
  }
}

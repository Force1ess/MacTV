import Foundation
import MTVCore

extension UISmoke {
  static func smbNetworkSmoke(model: AppModel, output: URL) async -> [String: Bool] {
    let source = model.captureLibrarySource()
    let store = model.smb.profileStore
    defer {
      model.smb.close()
      model.smb.connectionObserverForTesting = nil
      model.smb.profileStore = store
      model.restoreLibrarySource(source)
      model.navigate(.home)
    }
    let controller = model.smb
    var checks: [String: Bool] = [:]
    func ready() async {
      for _ in 0..<150 {
        if !controller.profilesLoading && controller.phase != "connecting" { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
    do {
      let file = output.appendingPathComponent("network-recovery/connections.json")
      let profiles = SMBProfileStore(file: file)
      var profile = try SMBProfile(
        address: "fixture.invalid/Movies/TV", username: "", guest: true, rememberPassword: false)
      try await profiles.upsert(profile)
      controller.profileStore = profiles
      controller.present(profileID: profile.id)
      await ready()
      controller.selection = controller.controls.firstIndex(of: .networkRecovery)!
      model.handle(.select)
      controller.selection = controller.controls.firstIndex(of: .saveProfile)!
      model.handle(.select)
      await controller.waitForPendingSaves()
      guard let loaded = try await profiles.load().first else {
        throw MTVError.message("测试重连偏好未保存")
      }
      profile = loaded
      checks["smbNetworkRecoveryPreferenceSavedExplicitly"] = profile.allowsAutomaticReconnect
      var requests = 0
      controller.connectionObserverForTesting = { location, user, password, guest in
        if location.shareURL.host == "fixture.invalid", location.subdirectory == ["TV"],
          user.isEmpty, password.isEmpty, guest
        {
          requests += 1
        }
      }
      controller.reconnectAutomatically(expected: profile)
      await ready()
      checks["smbAutomaticRecoveryUsesMatchingSavedParameters"] =
        requests == 1 && !controller.readOnlyConnected
      controller.close()
      var disabled = profile
      disabled.reconnectOnNetworkReturn = false
      try await profiles.upsert(disabled)
      controller.reconnectAutomatically(expected: profile)
      await ready()
      checks["smbAutomaticRecoveryRechecksLatestOptOut"] =
        requests == 1 && controller.message == L("已保存连接无法读取：\(L("自动重连设置或认证目标已改变，请手动确认"))")
      controller.close()
      var changed = profile
      changed.address = try SMBProfile.canonicalAddress("other.invalid/Movies/TV")
      try await profiles.upsert(changed)
      controller.reconnectAutomatically(expected: profile)
      await ready()
      checks["smbAutomaticRecoveryRejectsChangedTargetBeforeCredentialRead"] =
        requests == 1 && controller.message == L("已保存连接无法读取：\(L("自动重连设置或认证目标已改变，请手动确认"))")
      controller.close()
      try await profiles.remove(profile.id)
      controller.reconnectAutomatically(expected: profile)
      await ready()
      checks["smbAutomaticRecoveryRejectsDeletedProfile"] =
        requests == 1 && controller.message == L("已保存连接无法读取：\(L("自动重连的连接已删除，请手动选择"))")
    } catch { checks["smbNetworkRecoveryFixtureFlow"] = false }
    return checks
  }
}

import Foundation
import MTVCore

extension UISmoke {
  nonisolated static func smbProfilePersistence(scope: String, write: Bool) async -> (
    checks: [String: Bool], error: String?
  ) {
    guard let id = UUID(uuidString: scope) else { return ([:], "测试范围必须是 UUID") }
    let scope = id.uuidString.lowercased()
    let store = SMBProfileStore(
      file: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/MTV/TestResults/SMBAppPersistence-\(scope)/connections.json"))
    let vault = SMBCredentialStore(service: "local.mtv.preview.smb-app-fixture." + scope)
    do {
      if write {
        guard try await store.load().isEmpty else { throw MTVError.message("当前测试范围已存在连接") }
        let profile = try SMBProfile(
          id: id, address: "smb://fixture.invalid/Movies/TV",
          username: "MTV_APP_PERSISTENCE_FIXTURE", guest: false, rememberPassword: true)
        try await Task.detached { try vault.save("MTV_APP_SMB_PERSISTENCE_ONLY", for: profile) }
          .value
        try await store.upsert(profile)
        return (["smbAppOwnPersistenceFixtureWritten": true], nil)
      }
      let profiles = try await store.load()
      guard profiles.count == 1, let profile = profiles.first, profile.id == id else {
        throw MTVError.message("没有当前测试范围的唯一连接")
      }
      let credential = try await Task.detached { try vault.load(for: profile) }.value
      let context =
        profile.address == "smb://fixture.invalid/Movies/TV"
        && profile.username == "MTV_APP_PERSISTENCE_FIXTURE"
      try await Task.detached { try vault.remove(profileID: id) }.value
      try await store.remove(id)
      return (
        [
          "smbAppCredentialSurvivedRelaunch": credential == "MTV_APP_SMB_PERSISTENCE_ONLY",
          "smbAppProfileContextSurvivedRelaunch": context,
          "smbAppOwnFixtureRemoved": try await store.load().isEmpty,
        ], nil
      )
    } catch {
      try? vault.remove(profileID: id)
      return ([:], error.localizedDescription)
    }
  }
}

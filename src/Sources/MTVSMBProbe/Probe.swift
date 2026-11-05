import Darwin
import Foundation
import MTVCore

@main enum Probe {
  @MainActor static func main() async throws {
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--offline-startup-write" {
      try await offlineStartupFixture(scope: CommandLine.arguments[2])
      return
    }
    if CommandLine.arguments.count == 3,
      ["--profile-persist-write", "--profile-persist-read"].contains(CommandLine.arguments[1])
    {
      try await profilePersistence(
        scope: CommandLine.arguments[2],
        write: CommandLine.arguments[1] == "--profile-persist-write")
      return
    }
    guard CommandLine.arguments.count >= 2 else {
      throw MTVError.message("Pass an explicit fixture SMB URL")
    }
    let location = try SMBLocation(CommandLine.arguments[1])
    let staleHandleTest = CommandLine.arguments.contains("--verify-stale-handle")
    if staleHandleTest {
      guard location.shareURL.host == "127.0.0.1", location.shareURL.path == "/MTVFixture", location.subdirectory.isEmpty else {
        throw MTVError.message("失效句柄测试只接受回环 MTVFixture")
      }
    }
    let client = SMBMountClient()
    let cancel = CommandLine.arguments.contains("--cancel-immediately")
    let result = await withCheckedContinuation { continuation in
      client.start(location: location, username: "", password: "", guest: true, deadlineSeconds: 8)
      {
        continuation.resume(returning: $0)
      }
      if cancel { client.cancel() }
    }
    var report: [String: Any] = [
      "kind": "smb-native-probe", "guest": true, "passwordRecorded": false,
    ]
    switch result {
    case .success(let share):
      report["mountSucceeded"] = true
      report["readOnlyVerified"] = share.readOnly
      report["currentMountValidated"] = (try? share.validateCurrentMount()) != nil
      let marker = try? share.withCurrentMount { try String(contentsOf: share.directory.appendingPathComponent("MTV-test.txt"), encoding: .utf8) }
      report["fixtureRead"] =
        marker?.trimmingCharacters(in: .whitespacesAndNewlines) == "MTV SMB fixture"
      if staleHandleTest {
        var bodyRan = false, returnedResult = false, postReadRejected = false
        do {
          _ = try share.withCurrentMount {
            bodyRan = true
            let value = try String(contentsOf: share.directory.appendingPathComponent("MTV-test.txt"), encoding: .utf8)
            guard Darwin.unmount(share.mount.path, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            return value
          }
          returnedResult = true
        } catch let failure as SMBFailure { postReadRejected = failure.stage == .mountValidation }
        report["mountLostDuringReadCannotPublishResult"] = bodyRan && !returnedResult && postReadRejected
      }
      let retirement = await SMBMountClient.disconnect(share)
      report["retirementOutcome"] = retirement.outcome
      report["retirementError"] = retirement.errorCode
      report["mountDirectoryRemoved"] = !FileManager.default.fileExists(atPath: share.mount.path)
      if staleHandleTest, retirement.outcome == "removed" {
        try FileManager.default.createDirectory(at: share.mount, withIntermediateDirectories: false)
        let localMarker = share.mount.appendingPathComponent("owned-local.txt")
        try Data("Owned local replacement; not network data".utf8).write(to: localMarker)
        defer { _ = Darwin.unlink(localMarker.path); _ = Darwin.rmdir(share.mount.path) }
        report["localReplacementExists"] = FileManager.default.fileExists(atPath: localMarker.path)
        var readInvoked = false, rejected = false, artworkRejected = false
        do { _ = try share.withCurrentMount { readInvoked = true; return try Data(contentsOf: localMarker) } }
        catch let failure as SMBFailure { rejected = failure.stage == .mountValidation && failure.category == .mountChanged }
        do { _ = try ArtworkFileReader.read(localMarker, access: .verifiedSMB(share)) }
        catch let failure as SMBFailure { artworkRejected = failure.stage == .mountValidation }
        report["staleHandleRejectedBeforeRead"] = rejected && !readInvoked
        report["staleHandleArtworkRejected"] = artworkRejected
      }
      if staleHandleTest { report["replacementDirectoryRemoved"] = !FileManager.default.fileExists(atPath: share.mount.path) }
    case .failure(let error):
      report["mountSucceeded"] = false
      report["cancelObserved"] = error is CancellationError
      report["error"] = error.localizedDescription
    }
    if cancel { try await Task.sleep(for: .seconds(1)) }
    print(
      String(
        decoding: try JSONSerialization.data(
          withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    if cancel { exit(report["cancelObserved"] as? Bool == true ? 0 : 1) }
    if report["mountSucceeded"] as? Bool != true || report["fixtureRead"] as? Bool != true {
      exit(1)
    }
    if staleHandleTest && (report["currentMountValidated"] as? Bool != true || report["mountLostDuringReadCannotPublishResult"] as? Bool != true || report["staleHandleRejectedBeforeRead"] as? Bool != true || report["staleHandleArtworkRejected"] as? Bool != true || report["replacementDirectoryRemoved"] as? Bool != true) { exit(1) }
  }
  static func offlineStartupFixture(scope: String) async throws {
    guard let id = UUID(uuidString: scope) else { throw MTVError.message("测试范围必须是 UUID") }
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/MTV/TestResults/SMBOfflineStartup-" + id.uuidString.lowercased())
    let profiles = SMBProfileStore(file: root.appendingPathComponent("connections.json"))
    guard try await profiles.load().isEmpty else { throw MTVError.message("测试范围已存在配置") }
    let profile = try SMBProfile(id: id, address: "smb://fixture.invalid/Movies", username: "", guest: true, rememberPassword: false)
    let mount = root.appendingPathComponent("OldTransientMount")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/MTV/Fixtures/ResumeFixture45.mp4")
    try FileManager.default.linkItem(at: fixture, to: mount.appendingPathComponent("Offline.Movie.2024.mp4"))
    let poster = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/GeneratedPoster.png")
    try FileManager.default.linkItem(at: poster, to: mount.appendingPathComponent("poster.jpg"))
    let files = try LibraryScanner.scanResult(root: mount).withSMBIdentity(profile: profile, mount: mount).items
    let indexes = SMBLibraryIndexStore(root: root.appendingPathComponent("indexes"), artwork: SMBArtworkCache(disk: ArtworkDiskStore(root: root.appendingPathComponent("artwork"))))
    try await indexes.save(files, profile: profile, mount: mount)
    try await profiles.upsert(profile)
    try await LibrarySourceStore(file: root.appendingPathComponent("source.json")).save(LibrarySourceSelection(smbProfileID: profile.id))
    try FileManager.default.removeItem(at: mount)
    let report: [String: Any] = ["kind": "smb-offline-startup-fixture", "pid": ProcessInfo.processInfo.processIdentifier,
      "metadataPersisted": true, "oldGeneratedMountRemoved": !FileManager.default.fileExists(atPath: mount.path),
      "networkRequested": false, "credentialRead": false]
    print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
  }
  static func profilePersistence(scope: String, write: Bool) async throws {
    guard let id = UUID(uuidString: scope) else { throw MTVError.message("测试范围必须是 UUID") }
    let scope = id.uuidString.lowercased()
    let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/MTV/TestResults/SMBProfilePersistence-\(scope)/connections.json")
    let store = SMBProfileStore(file: file)
    let vault = SMBCredentialStore(service: "local.mtv.preview.smb-probe." + scope)
    var checks: [String: Bool] = [:]
    do {
      if write {
        guard try await store.load().isEmpty else { throw MTVError.message("该测试范围已有记录") }
        let profile = try SMBProfile(
          id: id, address: "smb://fixture.invalid/Movies/TV",
          username: "MTV_PERSISTENCE_FIXTURE", guest: false, rememberPassword: true)
        try await Task.detached { try vault.save("MTV_SMB_PERSISTENCE_FIXTURE_ONLY", for: profile) }
          .value
        try await store.upsert(profile)
        checks["ownProfileAndCredentialWritten"] = true
      } else {
        let profiles = try await store.load()
        guard profiles.count == 1, let profile = profiles.first, profile.id == id else {
          throw MTVError.message("没有当前测试范围的唯一记录")
        }
        let value = try await Task.detached { try vault.load(for: profile) }.value
        checks["credentialSurvivedNewProcess"] = value == "MTV_SMB_PERSISTENCE_FIXTURE_ONLY"
        checks["profileContextSurvivedNewProcess"] =
          profile.address == "smb://fixture.invalid/Movies/TV"
          && profile.username == "MTV_PERSISTENCE_FIXTURE"
        try await Task.detached { try vault.remove(profileID: id) }.value
        try await store.remove(id)
        checks["ownMetadataFixtureRemoved"] = try await store.load().isEmpty
      }
      checks["metadataContainsNoPassword"] = !String(
        decoding: try Data(contentsOf: file), as: UTF8.self
      )
      .contains("MTV_SMB_PERSISTENCE_FIXTURE_ONLY")
      let report: [String: Any] = [
        "kind": "smb-profile-persistence", "pid": ProcessInfo.processInfo.processIdentifier,
        "mode": write ? "write" : "read-and-clean", "scope": scope, "checks": checks,
        "passed": checks.values.allSatisfy { $0 }, "networkRequested": false,
        "realCredentialRead": false,
      ]
      print(
        String(
          decoding: try JSONSerialization.data(
            withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
      if !checks.values.allSatisfy({ $0 }) { exit(1) }
    } catch {
      try? vault.remove(profileID: id)
      throw error
    }
  }
}

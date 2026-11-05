import Darwin
import Foundation
import NetFS

public struct MountedSMBShare: Hashable, Sendable {
  public let mount: URL
  public let directory: URL
  public let readOnly: Bool
  let signature: SMBMountSignature
  public func validateCurrentMount() throws {
    let parent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Mounts")
    do { try SMBRetirementPolicy.requireCurrent(mount: mount, parent: parent, signature: signature, system: NativeSMBRetirementSystem()) }
    catch { throw SMBFailure(error, stage: .mountValidation) }
  }
  public func withCurrentMount<T>(_ operation: () throws -> T) throws -> T {
    try validateCurrentMount()
    let result = try operation()
    try validateCurrentMount()
    return result
  }
}

private final class MountRequestToken: @unchecked Sendable {
  let value: UnsafeMutableRawPointer
  init(_ value: UnsafeMutableRawPointer) { self.value = value }
}

/// Native SMB mounting, with a private mountpoint and no authentication dialogs.
/// Only cancels or cleans paths allocated for this request, never Finder mounts.
@MainActor public final class SMBMountClient {
  private var request: MountRequestToken?
  private var generation = UUID()
  private var timeout: Task<Void, Never>?
  private var completion: ((Result<MountedSMBShare, Error>) -> Void)?
  private var pendingMount: URL?
  public init() {}

  public func start(
    location: SMBLocation, username: String, password: String, guest: Bool,
    deadlineSeconds: Double = 25,
    completion: @escaping (Result<MountedSMBShare, Error>) -> Void
  ) {
    cancel()
    let attempt = UUID()
    generation = attempt
    self.completion = completion
    do {
      guard
        guest
          || (!username.isEmpty && !password.isEmpty && username.utf8.count <= 256
            && password.utf8.count <= 4096),
        !username.contains("\n"), !username.contains("\r")
      else {
        throw MTVError.message("请填写账号，或明确选择访客访问")
      }
      let parent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/MTV/Mounts", isDirectory: true)
      let mount = parent.appendingPathComponent(attempt.uuidString, isDirectory: true)
      try FileManager.default.createDirectory(
        at: mount, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      pendingMount = mount
      let open = NSMutableDictionary(dictionary: [
        "UIOption": "NoUI", "Guest": guest, "ForceNewSession": true, "AllowLoopback": true,
      ])
      let options = NSMutableDictionary(dictionary: [
        "MountFlags": NSNumber(value: MNT_RDONLY | MNT_DONTBROWSE), "MountAtMountDir": true,
      ])
      var identifier: UnsafeMutableRawPointer?
      let status = NetFSMountURLAsync(
        location.shareURL as CFURL, mount as CFURL,
        (guest ? "" : username) as CFString, (guest ? "" : password) as CFString,
        open, options, &identifier, .main
      ) { [weak self] status, _, points in
        // This callback is submitted to DispatchQueue.main. Clear the native
        // request synchronously before its callback lifetime ends; a later Cancel
        // must not use an already-completed native request identifier.
        MainActor.assumeIsolated {
          if self?.generation == attempt { self?.request = nil }
        }
        Task { @MainActor in
          guard let self, self.generation == attempt else {
            Task.detached { Self.cleanup(mount) }
            return
          }
          self.request = nil
          do {
            guard status == 0, let paths = points as? [String], paths.contains(mount.path) else {
              throw Self.error(status)
            }
            let mounted = try await Task.detached(priority: .utility) {
              try Self.verify(mount: mount, location: location)
            }.value
            guard self.generation == attempt else {
              Task.detached { Self.cleanup(mount) }
              return
            }
            self.timeout?.cancel()
            self.timeout = nil
            self.pendingMount = nil
            self.finish(
              .success(mounted))
          } catch {
            Task.detached { Self.cleanup(mount) }
            guard self.generation == attempt else { return }
            self.timeout?.cancel()
            self.timeout = nil
            self.pendingMount = nil
            self.finish(.failure(error))
          }
        }
      }
      guard status == 0, let identifier else { throw Self.error(status) }
      request = MountRequestToken(identifier)
      timeout = Task { [weak self] in
        do { try await Task.sleep(for: .seconds(max(1, min(60, deadlineSeconds)))) } catch {
          return
        }
        guard let self, self.generation == attempt else { return }
        self.cancel(reason: MTVError.message("连接超时，请检查服务器地址与网络"))
      }
    } catch { cancel(reason: error) }
  }
  public func cancel() { cancel(reason: CancellationError()) }
  @discardableResult public nonisolated static func disconnect(_ share: MountedSMBShare) async -> SMBMountRetirement {
    await Task.detached { cleanup(share.mount, signature: share.signature) }.value
  }
  private func cancel(reason: Error) {
    generation = UUID()
    timeout?.cancel()
    timeout = nil
    let token = request
    let mount = pendingMount
    request = nil
    pendingMount = nil
    if token != nil || mount != nil {
      Task.detached {
        if let token { _ = NetFSMountURLCancel(token.value) }
        if let mount { Self.cleanup(mount) }
      }
    }
    finish(.failure(reason))
  }
  private func finish(_ result: Result<MountedSMBShare, Error>) {
    let callback = completion
    completion = nil
    callback?(result)
  }
  nonisolated private static func verify(mount: URL, location: SMBLocation) throws
    -> MountedSMBShare
  {
    var info = statfs()
    guard statfs(mount.path, &info) == 0, info.f_flags & UInt32(MNT_RDONLY) != 0 else {
      throw MTVError.message("未获得只读 SMB 连接")
    }
    let type = withUnsafePointer(to: &info.f_fstypename) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSTYPENAMELEN)) { String(cString: $0) }
    }
    let mountedAt = withUnsafePointer(to: &info.f_mntonname) {
      $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    guard type == "smbfs", mountedAt == mount.path else { throw MTVError.message("未获得独立 SMB 挂载点") }
    let directory = try location.directory(in: mount)
    let share = MountedSMBShare(mount: mount, directory: directory, readOnly: true, signature: SMBMountSignature(info))
    try share.validateCurrentMount()
    try SMBDirectoryAccess.requireDirectory(directory)
    try share.validateCurrentMount()
    return share
  }
  @discardableResult nonisolated private static func cleanup(_ mount: URL, signature: SMBMountSignature? = nil) -> SMBMountRetirement {
    let parent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/MTV/Mounts")
    return SMBRetirementPolicy.reclaim(mount: mount, parent: parent, signature: signature,
      system: NativeSMBRetirementSystem())
  }
  nonisolated private static func error(_ status: Int32) -> Error {
    SMBFailure.netFS(status)
  }
}

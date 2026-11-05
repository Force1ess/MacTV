import Darwin
import Foundation

public struct SMBMountSignature: Hashable, Sendable {
  let fileSystemID: Data
  let owner: UInt32
  init(_ info: statfs) {
    var id = info.f_fsid
    fileSystemID = withUnsafeBytes(of: &id) { Data($0) }
    owner = info.f_owner
  }
  init(fileSystemID: Data, owner: UInt32) {
    self.fileSystemID = fileSystemID
    self.owner = owner
  }
}
public struct SMBMountRetirement: Codable, Equatable, Sendable {
  public let mountID: String
  public let outcome: String
  public let errorCode: Int32?
}
struct SMBMountRecord {
  let path: String
  let type: String
  let readOnly: Bool
  let signature: SMBMountSignature
}
protocol SMBRetirementSystem {
  func record(at path: String) throws -> SMBMountRecord?
  func unmount(_ path: String) -> Int32
  func removeEmptyDirectory(_ path: String) -> Int32
}
struct NativeSMBRetirementSystem: SMBRetirementSystem {
  func record(at path: String) throws -> SMBMountRecord? {
    let count = getfsstat(nil, 0, MNT_NOWAIT)
    guard count >= 0, count < 8192 else { throw POSIXError(.EIO) }
    var records = Array<Darwin.statfs>(repeating: Darwin.statfs(), count: Int(count) + 16)
    let read = records.withUnsafeMutableBufferPointer {
      getfsstat($0.baseAddress, Int32($0.count * MemoryLayout<statfs>.stride), MNT_NOWAIT)
    }
    guard read >= 0, read < records.count else { throw POSIXError(.EIO) }
    for info in records.prefix(Int(read)) {
      let mountedAt = withUnsafeBytes(of: info.f_mntonname) {
        String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
      }
      if mountedAt == path {
        let type = withUnsafeBytes(of: info.f_fstypename) {
          String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return SMBMountRecord(
          path: mountedAt, type: type, readOnly: info.f_flags & UInt32(MNT_RDONLY) != 0,
          signature: SMBMountSignature(info))
      }
    }
    return nil
  }
  func unmount(_ path: String) -> Int32 { Darwin.unmount(path, 0) == 0 ? 0 : errno }
  func removeEmptyDirectory(_ path: String) -> Int32 { Darwin.rmdir(path) == 0 ? 0 : errno }
}
enum SMBRetirementPolicy {
  static func privatePath(_ mount: URL, parent: URL) -> Bool {
    mount.isFileURL && mount.deletingLastPathComponent().standardizedFileURL.path == parent.standardizedFileURL.path
      && UUID(uuidString: mount.lastPathComponent) != nil
  }
  static func matches(_ current: SMBMountRecord, mount: URL, signature: SMBMountSignature?, owner: UInt32) -> Bool {
    current.path == mount.path && current.type == "smbfs" && current.readOnly && current.signature.owner == owner
      && (signature.map { $0 == current.signature } ?? true)
  }
  static func requireCurrent(mount: URL, parent: URL, signature: SMBMountSignature,
    system: any SMBRetirementSystem, owner: UInt32 = geteuid()) throws {
    guard privatePath(mount, parent: parent) else { throw SMBFailure.mountChanged(3) }
    guard let current = try system.record(at: mount.path) else { throw SMBFailure.mountChanged(1) }
    guard matches(current, mount: mount, signature: signature, owner: owner) else { throw SMBFailure.mountChanged(2) }
  }
  static func reclaim(
    mount: URL, parent: URL, signature: SMBMountSignature?, system: any SMBRetirementSystem,
    owner: UInt32 = geteuid()
  ) -> SMBMountRetirement {
    func result(_ outcome: String, _ error: Int32? = nil) -> SMBMountRetirement {
      SMBMountRetirement(mountID: mount.lastPathComponent, outcome: outcome, errorCode: error)
    }
    guard privatePath(mount, parent: parent)
    else { return result("refused-path") }
    do {
      if let current = try system.record(at: mount.path) {
        guard matches(current, mount: mount, signature: signature, owner: owner)
        else { return result("refused-identity") }
        let status = system.unmount(mount.path)
        guard status == 0 else {
          return result(status == EBUSY ? "busy" : "unmount-failed", status)
        }
      }
      let status = system.removeEmptyDirectory(mount.path)
      return status == 0 || status == ENOENT
        ? result("removed") : result("directory-retained", status)
    } catch { return result("inspection-failed") }
  }
}

private final class RetirementRace: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<[SMBMountRetirement], Never>?
  private let ids: [String]
  private var completed: [String: SMBMountRetirement] = [:]
  init(_ continuation: CheckedContinuation<[SMBMountRetirement], Never>, ids: [String]) {
    self.continuation = continuation
    self.ids = ids
  }
  func record(_ result: SMBMountRetirement) {
    lock.lock()
    completed[result.mountID] = result
    let done = completed.count == ids.count
    let pending = done ? continuation : nil
    if done { continuation = nil }
    let values = ids.compactMap { completed[$0] }
    lock.unlock()
    pending?.resume(returning: values)
  }
  func timeout() {
    lock.lock()
    let pending = continuation
    continuation = nil
    let values = ids.map {
      completed[$0] ?? SMBMountRetirement(mountID: $0, outcome: "deferred", errorCode: nil)
    }
    lock.unlock()
    pending?.resume(returning: values)
  }
}
enum SMBRetirementRunner {
  static func run(
    ids: [String], deadline: Double,
    operation: @escaping @Sendable (String) async -> SMBMountRetirement
  ) async -> [SMBMountRetirement] {
    guard !ids.isEmpty else { return [] }
    return await withCheckedContinuation { continuation in
      let race = RetirementRace(continuation, ids: ids)
      Task.detached { for id in ids { race.record(await operation(id)) } }
      Task.detached {
        try? await Task.sleep(for: .seconds(max(0.1, min(5, deadline))))
        race.timeout()
      }
    }
  }
}
extension SMBMountClient {
  public nonisolated static func retire(_ shares: [MountedSMBShare], deadline: Double = 2) async
    -> [SMBMountRetirement]
  {
    let known = Dictionary(
      shares.map { ($0.mount.lastPathComponent, $0) }, uniquingKeysWith: { first, _ in first })
    return await SMBRetirementRunner.run(ids: known.keys.sorted(), deadline: deadline) { id in
      var result = await disconnect(known[id]!)
      for _ in 0..<2 where result.outcome == "busy" {
        try? await Task.sleep(for: .milliseconds(100))
        result = await disconnect(known[id]!)
      }
      return result
    }
  }
}

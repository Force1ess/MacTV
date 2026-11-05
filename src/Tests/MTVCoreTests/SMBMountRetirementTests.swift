import Darwin
import Foundation
import Testing

@testable import MTVCore

private final class RetirementSystemFixture: SMBRetirementSystem {
  var mounted: SMBMountRecord?
  var unmountStatus: Int32 = 0
  var directoryStatus: Int32 = 0
  var inspectionFails = false
  var operations: [String] = []
  func record(at path: String) throws -> SMBMountRecord? {
    if inspectionFails { throw POSIXError(.EIO) }
    return mounted
  }
  func unmount(_ path: String) -> Int32 {
    operations.append("unmount")
    return unmountStatus
  }
  func removeEmptyDirectory(_ path: String) -> Int32 {
    operations.append("rmdir")
    return directoryStatus
  }
}
struct SMBMountRetirementTests {
  @Test func liveValidationAcceptsExactRecordWithoutMutatingFilesystem() throws {
    let mount = parent.appendingPathComponent(UUID().uuidString), system = RetirementSystemFixture()
    system.mounted = SMBMountRecord(path: mount.path, type: "smbfs", readOnly: true, signature: signature())
    try SMBRetirementPolicy.requireCurrent(mount: mount, parent: parent, signature: signature(), system: system, owner: 501)
    #expect(system.operations.isEmpty)
  }
  @Test func liveValidationRejectsAbsentReplacedOwnerTypeAndWritableMounts() {
    let mount = parent.appendingPathComponent(UUID().uuidString)
    let cases: [SMBMountRecord?] = [nil,
      SMBMountRecord(path: mount.path, type: "apfs", readOnly: true, signature: signature()),
      SMBMountRecord(path: mount.path, type: "smbfs", readOnly: false, signature: signature()),
      SMBMountRecord(path: mount.path, type: "smbfs", readOnly: true, signature: signature(2)),
      SMBMountRecord(path: mount.path, type: "smbfs", readOnly: true, signature: signature(owner: 0)),
      SMBMountRecord(path: "/other", type: "smbfs", readOnly: true, signature: signature())]
    for record in cases {
      let system = RetirementSystemFixture(); system.mounted = record
      #expect(throws: SMBFailure.self) { try SMBRetirementPolicy.requireCurrent(mount: mount, parent: parent, signature: signature(), system: system, owner: 501) }
      #expect(system.operations.isEmpty)
    }
  }
  @Test func liveValidationRefusesUnknownPathsAndInspectionFailure() {
    let system = RetirementSystemFixture()
    #expect(throws: SMBFailure.self) { try SMBRetirementPolicy.requireCurrent(mount: URL(fileURLWithPath: "/Volumes/FinderShare"), parent: parent, signature: signature(), system: system, owner: 501) }
    system.inspectionFails = true
    #expect(throws: (any Error).self) { try SMBRetirementPolicy.requireCurrent(mount: parent.appendingPathComponent(UUID().uuidString), parent: parent, signature: signature(), system: system, owner: 501) }
    #expect(system.operations.isEmpty)
  }
  let parent = URL(fileURLWithPath: "/tmp/mtv-owned-mounts")
  func signature(_ byte: UInt8 = 1, owner: UInt32 = 501) -> SMBMountSignature {
    SMBMountSignature(fileSystemID: Data(repeating: byte, count: 8), owner: owner)
  }
  @Test func exactOwnedReadOnlySMBMountIsUnmountedThenOnlyEmptyDirectoryRemoved() {
    let mount = parent.appendingPathComponent(UUID().uuidString)
    let system = RetirementSystemFixture()
    system.mounted = SMBMountRecord(
      path: mount.path, type: "smbfs", readOnly: true, signature: signature())
    let report = SMBRetirementPolicy.reclaim(
      mount: mount, parent: parent, signature: signature(), system: system, owner: 501)
    #expect(report.outcome == "removed")
    #expect(system.operations == ["unmount", "rmdir"])
  }
  @Test func wrongFileSystemIdentityOwnerAndTypeAreNeverUnmounted() {
    let mount = parent.appendingPathComponent(UUID().uuidString)
    for record in [
      SMBMountRecord(path: mount.path, type: "apfs", readOnly: true, signature: signature()),
      SMBMountRecord(path: mount.path, type: "smbfs", readOnly: false, signature: signature()),
      SMBMountRecord(path: mount.path, type: "smbfs", readOnly: true, signature: signature(2)),
      SMBMountRecord(
        path: mount.path, type: "smbfs", readOnly: true, signature: signature(owner: 0)),
    ] {
      let system = RetirementSystemFixture()
      system.mounted = record
      #expect(
        SMBRetirementPolicy.reclaim(
          mount: mount, parent: parent, signature: signature(), system: system, owner: 501
        ).outcome == "refused-identity")
      #expect(system.operations.isEmpty)
    }
  }
  @Test func busyAndUnknownPathsDoNotRemoveDirectories() {
    let mount = parent.appendingPathComponent(UUID().uuidString)
    let system = RetirementSystemFixture()
    system.mounted = SMBMountRecord(
      path: mount.path, type: "smbfs", readOnly: true, signature: signature())
    system.unmountStatus = EBUSY
    #expect(
      SMBRetirementPolicy.reclaim(
        mount: mount, parent: parent, signature: signature(), system: system, owner: 501
      ).outcome == "busy")
    #expect(system.operations == ["unmount"])
    system.operations = []
    let outside = URL(fileURLWithPath: "/Volumes/FinderShare")
    #expect(
      SMBRetirementPolicy.reclaim(mount: outside, parent: parent, signature: nil, system: system)
        .outcome == "refused-path")
    #expect(system.operations.isEmpty)
    system.inspectionFails = true
    #expect(
      SMBRetirementPolicy.reclaim(
        mount: mount, parent: parent, signature: signature(), system: system
      ).outcome == "inspection-failed")
    #expect(system.operations.isEmpty)
  }
  @Test func absentMountOnlyRemovesEmptyOwnedDirectoryAndLeavesNonemptyAlone() {
    let mount = parent.appendingPathComponent(UUID().uuidString)
    let system = RetirementSystemFixture()
    system.directoryStatus = ENOTEMPTY
    #expect(
      SMBRetirementPolicy.reclaim(
        mount: mount, parent: parent, signature: signature(), system: system
      ).outcome == "directory-retained")
    #expect(system.operations == ["rmdir"])
  }
  @Test func cleanupDeadlinePreservesCompletedResultsAndDoesNotWaitForBlockedOperation() async {
    let (blocked, release) = AsyncStream<Void>.makeStream()
    // Keep the operation blocked until the caller returns. A watchdog only
    // prevents a broken implementation from hanging the test indefinitely.
    let watchdog = Task {
      do { try await Task.sleep(for: .seconds(10)); release.finish() }
      catch { }
    }
    defer { watchdog.cancel(); release.finish() }
    let reports = await SMBRetirementRunner.run(ids: ["fast", "slow"], deadline: 0.1) { id in
      if id == "slow" { for await _ in blocked { } }
      return SMBMountRetirement(mountID: id, outcome: "removed", errorCode: nil)
    }
    #expect(reports.first?.outcome == "removed" && reports.last?.outcome == "deferred")
  }
}

import AppKit
import Darwin
import MTVCore

private final class OwnedSelectionDelay: @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0, mainThreadCalls = 0
  func resolve(_ url: URL, _ root: URL) throws -> SMBDirectorySelection {
    lock.lock(); calls += 1; if Thread.isMainThread { mainThreadCalls += 1 }; lock.unlock()
    Thread.sleep(forTimeInterval: 0.35)
    return try SMBDirectoryAccess.selection(in: url, allowedRoot: root)
  }
  var observed: (calls: Int, mainThread: Int) {
    lock.lock(); defer { lock.unlock() }; return (calls, mainThreadCalls)
  }
}

extension UISmoke {
  static func smbFailureSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    let source = model.captureLibrarySource(), controller = model.smb
    let oldSelect = controller.onSelect
    var checks: [String: Bool] = [:], handoffs = 0
    defer {
      controller.close(); controller.directoryReaderForTesting = nil; controller.directoryDeadlineForTesting = nil
      controller.directorySelectionResolverForTesting = nil; controller.onDirectorySelectionForTesting = nil
      controller.connectionObserverForTesting = nil; controller.onSelect = oldSelect
      model.notice = nil; model.restoreLibrarySource(source); model.navigate(.home)
    }
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<400 { if condition() { return }; try? await Task.sleep(for: .milliseconds(10)) }
    }
    do {
      model.navigate(.settings)
      let error = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES), userInfo: [NSLocalizedDescriptionKey: "SMB-SECRET-FIXTURE"] )])
      controller.showFailureForTesting(error, stage: .directoryRead)
      await wait { !controller.profilesLoading }
      controller.onSelect = { _, _, _ in handoffs += 1 }
      checks["smbPermissionEvidenceDoesNotBecomeAuthenticationOrSuccess"] = controller.failure?.category == .accessDenied && !controller.readOnlyConnected
      if let index = controller.controls.firstIndex(of: .failureDetails) { controller.selection = index; model.handle(.select) }
      checks["smbFailureDetailsRemoteShowsSafeDomainCodes"] = model.notice?.contains("NSCocoaErrorDomain 257") == true
        && model.notice?.contains("NSPOSIXErrorDomain 13") == true && model.notice?.contains("SMB-SECRET-FIXTURE") == false
      await settle(); capture(window, to: output.appendingPathComponent("smb-failure-details.png"))
      model.handle(.back)
      checks["smbFailureDetailsBackReturnsToForm"] = model.notice == nil && controller.isPresented
      let root = output.appendingPathComponent("owned-directory")
      try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder"), withIntermediateDirectories: true)
      controller.readDirectoryForTesting(root, allowedRoot: root); await wait { !controller.directoryReadPending }
      if let data = try? JSONSerialization.data(withJSONObject: ["expectedPath": root.resolvingSymlinksInPath().standardizedFileURL.path,
        "actualPath": controller.directory?.path ?? "", "folderCount": controller.folders.count, "phase": controller.phase,
        "readOnlyConnected": controller.readOnlyConnected]) { try? data.write(to: output.appendingPathComponent("owned-directory-evidence.json")) }
      let expected = root.resolvingSymlinksInPath().standardizedFileURL.path
      checks["smbOwnedLocalDirectoryReaderDoesNotFabricateMount"] = controller.directory?.path == expected && controller.folders.count == 1 && !controller.readOnlyConnected
      controller.readDirectoryForTesting(root.appendingPathComponent("missing"), allowedRoot: root); await wait { !controller.directoryReadPending }
      checks["smbFailedChildCannotHandOffPreviousReadableParent"] = controller.phase == "browseError"
        && controller.failure?.category == .missing && controller.directory?.path == expected && !controller.controls.contains(.useDirectory) && handoffs == 0
      checks["smbNoVerifiedMountCannotOfferMountedRetryOrRoot"] = !controller.controls.contains(.retryDirectory) && !controller.controls.contains(.browseRoot)
      await settle(); capture(window, to: output.appendingPathComponent("smb-missing-directory.png"))
      var reads = 0, connections = 0
      controller.directoryDeadlineForTesting = 0.05
      controller.directoryReaderForTesting = { url, allowed in
        reads += 1; try? await Task.sleep(for: .milliseconds(350))
        return try SMBDirectoryAccess.children(in: url, allowedRoot: allowed)
      }
      controller.connectionObserverForTesting = { _, _, _, _ in connections += 1 }
      controller.guest = true; controller.address = "smb://fixture.invalid/Movies"
      controller.readDirectoryForTesting(root, allowedRoot: root)
      await wait { controller.phase == "browseError" && controller.directoryReadPending }
      checks["smbReadTimeoutKeepsOutstandingReadPending"] = controller.directoryReadPending && controller.failure?.category == .timeout
      controller.readDirectoryForTesting(root, allowedRoot: root); controller.connect()
      checks["smbPendingReadPreventsDuplicateReadAndConnection"] = reads == 1 && connections == 0 && !controller.readOnlyConnected
      controller.selection = controller.controls.firstIndex(of: .close) ?? 0
      await wait { !controller.directoryReadPending }
      checks["smbTimedOutReadCompletionPreservesErrorAndSelectedControl"] = controller.phase == "browseError"
        && controller.controls[controller.selection] == .close && !controller.controls.contains(.useDirectory)
      controller.readDirectoryForTesting(root, allowedRoot: root)
      await wait { controller.phase == "browseError" && controller.directoryReadPending }
      controller.close(); await wait { !controller.directoryReadPending }
      checks["smbLateReadAfterCloseCannotRestoreDirectoryOrHandOff"] = !controller.isPresented && controller.directory == nil && controller.folders.isEmpty && handoffs == 0
      controller.showFailureForTesting(SMBFailure.mountChanged(1), stage: .mountValidation)
      await wait { !controller.profilesLoading }
      checks["smbLostMountOffersReconnectionInsteadOfDirectoryRetry"] = controller.controls.contains(.reconnect)
        && !controller.controls.contains(.retryDirectory) && !controller.controls.contains(.browseRoot) && !controller.readOnlyConnected
      if let index = controller.controls.firstIndex(of: .reconnect) { controller.selection = index; model.handle(.select) }
      checks["smbReconnectionActionReturnsToSettingsWithoutConnecting"] = controller.phase == "form" && connections == 0 && handoffs == 0 && controller.controls.contains(.address)
      controller.directoryReaderForTesting = nil
      var selections: [SMBDirectorySelection] = []
      controller.onDirectorySelectionForTesting = { selections.append($0) }
      controller.directoryDeadlineForTesting = 2
      controller.selectDirectoryForTesting(root.appendingPathComponent("Folder"), allowedRoot: root)
      await wait { !controller.directoryReadPending }
      checks["smbOwnedSelectionResolvesWithoutFabricatingMount"] = selections.count == 1
        && selections.first?.relativePath == "/Folder" && !controller.readOnlyConnected && handoffs == 0
      selections = []
      let delay = OwnedSelectionDelay()
      controller.directorySelectionResolverForTesting = { try delay.resolve($0, $1) }
      controller.directoryDeadlineForTesting = 0.08
      controller.selectDirectoryForTesting(root, allowedRoot: root)
      await wait { controller.phase == "browseError" }
      checks["smbSelectionTimeoutRunsWhileFilesystemWorkerIsPending"] = controller.directoryReadPending
        && controller.failure?.stage == .directoryVerification && controller.failure?.category == .timeout
        && delay.observed.calls == 1 && delay.observed.mainThread == 0
      controller.selectDirectoryForTesting(root, allowedRoot: root); controller.connect()
      checks["smbPendingSelectionBlocksDuplicateVerificationAndConnection"] = delay.observed.calls == 1 && connections == 0
      model.handle(.back)
      checks["smbRemoteBackClosesWhileSelectionWorkerStillPending"] = !controller.isPresented && controller.directoryReadPending
      controller.present(); await wait { !controller.profilesLoading }
      let reopenedPhase = controller.phase
      await wait { !controller.directoryReadPending }
      checks["smbLateSelectionCannotReachAcceptedSelectionAfterReopen"] = controller.isPresented
        && controller.phase == reopenedPhase && selections.isEmpty && handoffs == 0
      controller.directorySelectionResolverForTesting = nil; controller.directoryDeadlineForTesting = 2
      controller.selectDirectoryForTesting(root.appendingPathComponent("missing"), allowedRoot: root)
      await wait { !controller.directoryReadPending }
      checks["smbMissingSelectionShowsVerificationFailureWithoutSuccess"] = controller.phase == "browseError"
        && controller.failure?.stage == .directoryVerification && controller.failure?.category == .missing && selections.isEmpty
      controller.selectDirectoryForTesting(root.appendingPathComponent("Folder"), allowedRoot: root)
      await wait { !controller.directoryReadPending }
      checks["smbSelectionCanRecoverAfterEarlierWorkerActuallyFinishes"] = selections.count == 1
        && selections.first?.relativePath == "/Folder" && handoffs == 0 && !controller.readOnlyConnected
      if let data = try? JSONSerialization.data(withJSONObject: ["workerCalls": delay.observed.calls,
        "mainThreadWorkerCalls": delay.observed.mainThread, "actualSMBMount": false, "actualHandoffs": handoffs]) {
        try? data.write(to: output.appendingPathComponent("selection-worker-evidence.json"))
      }
    } catch { checks["smbFailureOwnedFixtureFlow"] = false }
    return checks
  }
}

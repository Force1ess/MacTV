import AppKit
import MTVCore

extension UISmoke {
  static func historyRecoverySmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of: "--history-test-scope"), index + 1 < args.count,
      let scope = UUID(uuidString: args[index + 1]) else { return ["recoveryExplicitPrivateScopeRequired": false] }
    let defaults = UserDefaults(suiteName: "local.mtv.preview.resume-fixture." + scope.uuidString.lowercased())!
    var checks: [String: Bool] = [:]
    func wait() async {
      for _ in 0..<300 { if !model.continueWatching.recoveryBusy { return }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    defer { model.continueWatching.closeRecovery(); model.notice = nil; model.navigate(.home) }
    do {
      model.stopPlayback()
      let damaged = Data("owned damaged history fixture".utf8)
      model.resumeStore.save(42, for: "recovery-owned-position", duration: 200)
      defaults.set(damaged, forKey: "watch-history.v1"); model.continueWatching.reload()
      checks["recoveryDamagedListHasVisibleErrorState"] = model.continueWatching.error != nil && model.continueWatching.entries.isEmpty
      await openSettingWithRemote(.history, model: model)
      checks["recoveryRemoteSettingsShowsConcreteReview"] = model.continueWatching.recoveryPresented
        && model.continueWatching.recoveryReview?.isDamaged == true && model.continueWatching.recoverySelection == 0
      await settle(); capture(window, to: output.appendingPathComponent("history-recovery-review.png"))
      model.handle(.select)
      checks["recoveryDefaultSelectionCancelsWithoutMutation"] = !model.continueWatching.recoveryPresented
        && defaults.data(forKey: "watch-history.v1") == damaged && model.continueWatching.lastRecoveryBackup == nil
      model.handle(.select); model.handle(.right); model.handle(.select)
      model.handle(.back)
      checks["recoveryBusyBackLeavesPanelWithoutInterruptingBackup"] = !model.continueWatching.recoveryPresented
      await wait()
      guard let backup = model.continueWatching.lastRecoveryBackup else { throw MTVError.message("未生成测试备份") }
      let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: backup), format: nil) as? [String: Any]
      checks["recoveryConfirmedActionBacksUpExactBadValue"] = value?["value"] as? Data == damaged
      checks["recoveryConfirmedActionRebuildsListAndPreservesPosition"] = model.continueWatching.error == nil
        && model.continueWatching.entries.isEmpty && model.resumeStore.position(for: "recovery-owned-position") == 42
      await settle(); capture(window, to: output.appendingPathComponent("history-recovery-success.png"))
      model.continueWatching.closeRecovery()
      let first = try PlaybackHistoryContext(mediaID: "recovery-owned-position", sourceID: "local", title: "测试观看记录", sourceTitle: "自有测试目录", librarySource: LibrarySourceSelection(path: output.path))
      try model.resumeStore.remember(first); model.continueWatching.reload()
      checks["recoveryMetadataAPIWorksAfterRebuild"] = model.continueWatching.entries.count == 1
      await openSettingWithRemote(.history, model: model)
      checks["recoveryValidListReviewShowsExactCount"] = model.continueWatching.recoveryReview?.recordCount == 1
      let second = try PlaybackHistoryContext(mediaID: "newer-owned-entry", sourceID: "local", title: "审阅后新增", sourceTitle: "自有测试目录", librarySource: LibrarySourceSelection(path: output.path))
      model.resumeStore.save(12, for: second.mediaID, duration: 100); try model.resumeStore.remember(second)
      model.handle(.right); model.handle(.select); await wait()
      let retained = try model.resumeStore.recent()
      checks["recoveryStaleReviewCannotClearNewerMetadata"] = model.continueWatching.recoveryMessage.contains("已变化")
        && retained.count == 2
      checks["recoveryStaleActionStillPreservesBothPositions"] = model.resumeStore.position(for: first.mediaID) == 42
        && model.resumeStore.position(for: second.mediaID) == 12
      await settle(); capture(window, to: output.appendingPathComponent("history-recovery-stale.png"))
    } catch { checks["recoveryOwnedFixtureExecution"] = false }
    return checks
  }
}

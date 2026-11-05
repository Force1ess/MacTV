import AppKit
import Darwin
import MTVCore

extension UISmoke {
  static func pluginRegistryRecoverySmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    let store = PluginClient.packages, id = "dev.mtvtests.registry"
    var running: Task<Data, Error>?
    defer { running?.cancel(); PluginClient.cancel(pluginID: id); model.pluginManager.close(); model.notice = nil; model.navigate(.home) }
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<300 { if condition() { return }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    func review() async {
      model.pluginManager.present(); await wait { !model.pluginManager.loading }
      model.pluginManager.selection = 2; model.handle(.select)
      await wait { !model.pluginManager.loading }
    }
    do {
      let root = await store.root, source = output.appendingPathComponent("owned-registry-plugin")
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
      let manifest: [String: Any] = ["id": id, "name": "安装清单测试模块", "version": "1.0", "apiVersion": 1,
        "entry": "plugin.js", "domains": [], "capabilities": ["browse"], "presentation": ["showOnHome": true]]
      try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("manifest.json"))
      try Data("const plugin={handle(action,input){if(input.slow==='1'){const t=Date.now();while(Date.now()-t<20000){}}return {items:[]};}};".utf8)
        .write(to: source.appendingPathComponent("plugin.js"))
      let prepared = try await store.prepare(directory: source); _ = try await store.approve(prepared.id)
      await model.reloadPluginCatalog()
      let old = try requirePlugin(model.plugins.first { $0.id == id })
      let builtins = Set(model.plugins.filter { $0.id.hasPrefix("mtv.") }.map(\.id))
      model.pluginManager.present(); await wait { !model.pluginManager.loading }
      checks["registryInitiallyHasApprovedExternalPackage"] = model.pluginManager.packages.count == 1
      running = Task { try await PluginClient.execute(old, action: "browse", input: ["slow": "1"]) }
      await wait { !PluginClient.runningProcessIDs(pluginID: id).isEmpty }
      let pids = PluginClient.runningProcessIDs(pluginID: id)
      let index = root.appendingPathComponent("installed.json"), damaged = Data("owned invalid registry fixture".utf8)
      try damaged.write(to: index)
      model.pluginManager.present(); await wait { !model.pluginManager.loading }
      checks["registryReadErrorClearsStaleRowsAndOffersRecovery"] = model.pluginManager.registryFailed
        && model.pluginManager.packages.isEmpty && model.pluginManager.controls.count == 3
      model.pluginManager.selection = 2; model.handle(.select); await wait { !model.pluginManager.loading }
      checks["registryRemoteReviewDefaultsToCancel"] = model.pluginManager.recoveryReview?.byteCount == damaged.count && model.pluginManager.selection == 0
      await settle(); capture(window, to: output.appendingPathComponent("registry-recovery-review.png"))
      model.handle(.select)
      let afterCancel = try Data(contentsOf: index)
      checks["registryCancelKeepsRawRegistryAndCode"] = model.pluginManager.recoveryReview == nil
        && afterCancel == damaged && FileManager.default.fileExists(atPath: old.directory.appendingPathComponent("plugin.js").path)
      await review(); model.pluginManager.selection = 1; model.handle(.select)
      await model.pluginManager.waitForPendingChanges()
      let registered = try await store.installed()
      let backup = model.pluginManager.lastRegistryBackup
      checks["registryConfirmBacksUpExactOriginalAndClearsOnlyRegistration"] = registered.isEmpty
        && backup.map { (try? Data(contentsOf: $0)) == damaged } == true
        && FileManager.default.fileExists(atPath: old.directory.appendingPathComponent("plugin.js").path)
        && FileManager.default.fileExists(atPath: source.appendingPathComponent("plugin.js").path)
      let outcome = await running?.result
      let cancelled: Bool; if case .some(.failure) = outcome { cancelled = true } else { cancelled = false }
      checks["registryResetCancelsObservedExternalWorker"] = !pids.isEmpty && cancelled && pids.allSatisfy { kill($0, 0) != 0 }
      checks["registryResetPreservesBuiltinModules"] = Set(model.plugins.filter { $0.id.hasPrefix("mtv.") }.map(\.id)) == builtins
      do { _ = try await PluginClient.execute(old, action: "browse"); checks["registryOldApprovalCannotExecute"] = false }
      catch { checks["registryOldApprovalCannotExecute"] = true }
      await settle(); capture(window, to: output.appendingPathComponent("registry-recovery-success.png"))
      let fresh = try await store.prepare(directory: source); _ = try await store.approve(fresh.id)
      await model.reloadPluginCatalog()
      let newer = try requirePlugin(model.plugins.first { $0.id == id })
      let valid = try Data(contentsOf: index)
      try damaged.write(to: index); await review()
      try valid.write(to: index)
      model.pluginManager.selection = 1; model.handle(.select); await model.pluginManager.waitForPendingChanges()
      let preserved = try Data(contentsOf: index)
      checks["registryStaleConfirmationPreservesNewValidRegistration"] = preserved == valid
        && model.pluginManager.registryFailed && model.pluginManager.recoveryReview == nil
      model.pluginManager.selection = 1; model.handle(.select); await wait { !model.pluginManager.loading }
      checks["registryReloadRecoversValidNewRowsWithoutReset"] = !model.pluginManager.registryFailed && model.pluginManager.packages.count == 1
      _ = try await PluginClient.execute(newer, action: "browse")
      checks["registryFreshApprovalStillExecutesAfterRejectedReset"] = true
      await settle(); capture(window, to: output.appendingPathComponent("registry-new-install-retained.png"))
      try await store.remove(id); await model.reloadPluginCatalog()
    } catch {
      checks["registryRecoveryUnexpectedFailure"] = false
      if let data = try? JSONSerialization.data(withJSONObject: ["error": String(error.localizedDescription.prefix(600))]) {
        try? data.write(to: output.appendingPathComponent("registry-fixture-error.json"))
      }
    }
    return checks
  }
}

private func requirePlugin(_ value: PluginRecord?) throws -> PluginRecord {
  guard let value else { throw MTVError.message("自建测试模块未安装") }; return value
}

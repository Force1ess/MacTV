import AppKit
import Darwin
import MTVCore

extension UISmoke {
  static func pluginInstallSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    let id = "dev.mtvtests.install"
    let source = output.appendingPathComponent("owned-plugin-source")
    var checks: [String: Bool] = [:]
    defer { model.pluginFolders.close(); model.pluginManager.close(); model.notice = nil; model.navigate(.home) }
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<300 { if condition() { return }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    func write(version: String) throws {
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
      let manifest: [String: Any] = ["id": id, "name": "外部安装测试", "version": version, "apiVersion": 1,
        "entry": "plugin.js", "domains": [], "capabilities": ["browse", "search"],
        "presentation": ["showOnHome": true, "summary": "自建测试模块，不使用网络"]]
      try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("manifest.json"))
      let code = """
      const plugin = {handle(action,input) {
        if(input.slow==='1') {const start=Date.now(); while(Date.now()-start<15000) {}}
        let denied=false; try {host.fetchJSON('https://not-approved.invalid/data');} catch(e) {denied=true;}
        return {items:[{id:'hello',title:'已安装的原生模块',subtitle:'原生页面',source:'fixture',overview:'版本 \(version)'}],
          runtime:{process:typeof process,require:typeof require,ObjC:typeof ObjC,domainDenied:denied}};
      }};
      """
      try Data(code.utf8).write(to: source.appendingPathComponent("plugin.js"))
      try Data("Generated fixture; no third-party source included.".utf8).write(to: source.appendingPathComponent("LICENSE"))
    }
    func selectPackage() {
      if let index = model.pluginManager.packages.firstIndex(where: { $0.id == id }) {
        model.pluginManager.selection = index + 2; model.handle(.select)
      }
    }
    do {
      let unsandboxed = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MTVPluginHost")
      do { try PluginHostIsolation.validate(unsandboxed); checks["pluginUnsandboxedDiagnosticHostCannotBeProductionHost"] = false }
      catch { checks["pluginUnsandboxedDiagnosticHostCannotBeProductionHost"] = true }
      try write(version: "1.0.0")
      let manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(contentsOf: source.appendingPathComponent("manifest.json")))
      let unapproved = PluginRecord(manifest: manifest, directory: source)
      do { _ = try await PluginClient.execute(unapproved, action: "browse"); checks["pluginUnapprovedCodeCannotRun"] = false }
      catch { checks["pluginUnapprovedCodeCannotRun"] = true }
      model.navigate(.extensions); model.focus.select(row: 1, column: model.plugins.count); model.handle(.select)
      await wait { model.pluginManager.isPresented && !model.pluginManager.loading }
      checks["pluginManagerRemoteEntry"] = model.pluginManager.isPresented
      model.pluginManager.selection = 1; model.handle(.select)
      await wait { model.pluginFolders.isPresented && !model.pluginFolders.loading }
      model.showPluginPath(); model.inputText = source.path; model.pressKey("完成")
      await wait { !model.pluginFolders.loading && model.pluginFolders.directory?.path == source.path }
      model.pluginFolders.selection = 0; model.handle(.select)
      await wait { !model.pluginManager.loading && model.pluginManager.review != nil }
      checks["pluginFolderAndScreenKeyboardPrepareReview"] = model.pluginManager.review?.manifest.id == id && !model.keyboardVisible && !model.pluginFolders.isPresented
      let before = try await PluginClient.packages.installed()
      checks["pluginReviewDoesNotInstallOrLaunch"] = before.isEmpty && PluginClient.runningProcessIDs(pluginID: id).isEmpty
      await settle(); capture(window, to: output.appendingPathComponent("plugin-review.png"))
      model.pluginManager.selection = 1; model.handle(.select); await model.pluginManager.waitForPendingChanges()
      let installed = model.plugins.first { $0.id == id }
      checks["pluginApprovalAddsNativeModule"] = installed != nil && model.homePlugins.contains { $0.id == id }
      guard let installed else { return checks }
      let result = try await PluginClient.execute(installed, action: "browse")
      let json = try JSONSerialization.jsonObject(with: result) as? [String: Any]
      let runtime = json?["runtime"] as? [String: Any]
      checks["pluginConstrainedHostHasNoNodeOrObjCGlobals"] = runtime?["process"] as? String == "undefined" && runtime?["require"] as? String == "undefined" && runtime?["ObjC"] as? String == "undefined"
      checks["pluginUndeclaredNetworkIsRejected"] = runtime?["domainDenied"] as? Bool == true
      model.pluginManager.close(); model.openModule(installed)
      await wait { !model.loading && !model.online.isEmpty }
      checks["pluginInstalledScriptRendersNativeContent"] = model.online.first?.title == "已安装的原生模块" && model.online.first?.source == id
      await settle(); capture(window, to: output.appendingPathComponent("plugin-native-module.png"))
      model.navigate(.extensions); model.pluginManager.present(); await wait { !model.pluginManager.loading }
      let slow = Task { try await PluginClient.execute(installed, action: "browse", input: ["slow": "1"]) }
      await wait { !PluginClient.runningProcessIDs(pluginID: id).isEmpty }
      let pids = PluginClient.runningProcessIDs(pluginID: id)
      selectPackage(); model.pluginManager.selection = 1; model.handle(.select)
      await model.pluginManager.waitForPendingChanges()
      let slowResult = await slow.result
      let failed: Bool; if case .failure = slowResult { failed = true } else { failed = false }
      checks["pluginDisableStopsObservedHostAndRemovesEntry"] = !pids.isEmpty && failed && pids.allSatisfy({ kill($0, 0) != 0 }) && !model.plugins.contains { $0.id == id }
      do { _ = try await PluginClient.execute(installed, action: "browse"); checks["pluginDisabledGrantCannotExecute"] = false }
      catch { checks["pluginDisabledGrantCannotExecute"] = true }
      selectPackage(); model.pluginManager.selection = 1; model.handle(.select); await model.pluginManager.waitForPendingChanges()
      checks["pluginEnableRestoresEntry"] = model.plugins.contains { $0.id == id }
      try write(version: "2.0.0")
      model.pluginManager.prepare(source); await wait { !model.pluginManager.loading }
      checks["pluginUpdateRequiresNewReview"] = model.pluginManager.review?.replacingVersion == "1.0.0"
      model.pluginManager.selection = 1; model.handle(.select); await model.pluginManager.waitForPendingChanges()
      checks["pluginReviewedUpdateReplacesEntry"] = model.plugins.first { $0.id == id }?.manifest.version == "2.0.0"
      do { _ = try await PluginClient.execute(installed, action: "browse"); checks["pluginOldReceiptCannotExecuteAfterUpdate"] = false }
      catch { checks["pluginOldReceiptCannotExecuteAfterUpdate"] = true }
      if let current = model.plugins.first(where: { $0.id == id }) {
        let parked = output.appendingPathComponent("parked-owned-package")
        try FileManager.default.moveItem(at: current.directory, to: parked)
        try FileManager.default.createSymbolicLink(at: current.directory, withDestinationURL: PluginClient.root.appendingPathComponent("example"))
        do { _ = try await PluginClient.execute(current, action: "browse"); checks["pluginManagedLinkCannotBecomeBundledCode"] = false }
        catch { checks["pluginManagedLinkCannotBecomeBundledCode"] = true }
        try FileManager.default.removeItem(at: current.directory)
        try FileManager.default.moveItem(at: parked, to: current.directory)
      }
      selectPackage(); model.pluginManager.selection = 2; model.handle(.select)
      let beforeRemoval = try await PluginClient.packages.installed()
      checks["pluginRemovalNeedsConfirmation"] = model.pluginManager.confirmingRemoval && beforeRemoval.contains { $0.id == id }
      model.pluginManager.selection = 1; model.handle(.select); await model.pluginManager.waitForPendingChanges()
      let remaining = try await PluginClient.packages.installed()
      checks["pluginRemovalKeepsSourceAndBuiltins"] = remaining.isEmpty && !model.plugins.contains { $0.id == id }
        && model.plugins.contains { $0.id == "mtv.bilibili" } && model.plugins.contains { $0.id == "mtv.quark" }
        && FileManager.default.fileExists(atPath: source.appendingPathComponent("plugin.js").path)
      model.pluginManager.close(); await model.pluginManager.waitForPendingChanges()
      if CommandLine.arguments.contains("--plugin-cold-write") {
        model.pluginManager.present(); await wait { !model.pluginManager.loading }
        model.pluginManager.prepare(source); await wait { !model.pluginManager.loading && model.pluginManager.review != nil }
        model.pluginManager.selection = 1; model.handle(.select); await model.pluginManager.waitForPendingChanges()
        checks["pluginColdStartupFixtureInstalled"] = model.plugins.first { $0.id == id }?.manifest.version == "2.0.0"
        model.pluginManager.close(); await model.pluginManager.waitForPendingChanges()
      }
    } catch { checks["pluginInstallFixtureSetup"] = false }
    return checks
  }
  static func pluginInstallColdRead(model: AppModel) async -> [String: Bool] {
    let id = "dev.mtvtests.install"
    var checks: [String: Bool] = [:]
    for _ in 0..<300 {
      if model.plugins.contains(where: { $0.id == id }) { break }
      try? await Task.sleep(for: .milliseconds(50))
    }
    guard let plugin = model.plugins.first(where: { $0.id == id }) else { return ["pluginColdStartupRestoresEntry": false] }
    checks["pluginColdStartupRestoresEntry"] = plugin.manifest.version == "2.0.0"
    model.openModule(plugin)
    for _ in 0..<300 {
      if !model.loading && !model.online.isEmpty { break }
      try? await Task.sleep(for: .milliseconds(50))
    }
    checks["pluginColdStartupExecutesApprovedContent"] = model.online.first?.title == "已安装的原生模块" && model.online.first?.overview == "版本 2.0.0"
    model.navigate(.extensions); model.pluginManager.present()
    for _ in 0..<100 { if !model.pluginManager.loading { break }; try? await Task.sleep(for: .milliseconds(50)) }
    if let index = model.pluginManager.packages.firstIndex(where: { $0.id == id }) {
      model.pluginManager.selection = index + 2; model.handle(.select)
      model.pluginManager.selection = 2; model.handle(.select)
      model.pluginManager.selection = 1; model.handle(.select)
      await model.pluginManager.waitForPendingChanges()
    }
    let empty = (try? await PluginClient.packages.installed().isEmpty) == true
    checks["pluginColdStartupFixtureRemovedWithoutBundledChanges"] = empty && model.plugins.contains { $0.id == "mtv.bilibili" } && model.plugins.contains { $0.id == "mtv.quark" }
    model.pluginManager.close(); await model.pluginManager.waitForPendingChanges(); model.navigate(.home)
    return checks
  }
}

import AppKit
import MTVCore

extension UISmoke {
  static func moduleRecoverySmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    let id = "dev.mtvtests.recovery"
    var checks: [String: Bool] = [:]
    func wait() async {
      for _ in 0..<300 { if !model.loading { return }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    func readyTime() -> String { String(Int(Date().timeIntervalSince1970 * 1000) + 2500) }
    func waitUntil(_ time: String) async {
      guard let target = Double(time) else { return }
      while Date().timeIntervalSince1970 * 1000 <= target + 100 {
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
    do {
      let source = output.appendingPathComponent("owned-recovery-plugin", isDirectory: true)
      try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
      let manifest: [String: Any] = ["presentation": ["symbol": "puzzlepiece.extension"], "localizedNames": ["en": "Fixture", "zh-Hans": "样例"], "id": id, "name": "恢复交互测试", "version": "1.0.0", "apiVersion": 1,
        "entry": "plugin.js", "domains": [], "capabilities": ["browse", "search", "folders"]]
      try JSONSerialization.data(withJSONObject: manifest).write(to: source.appendingPathComponent("manifest.json"))
      let code = """
      const plugin={handle(action,input){
        if(input.slow==='1'){const started=Date.now();while(Date.now()-started<2000){}}
        if(input.fail==='1'||Date.now()<Number(input.readyAfter||0))throw Error('自建服务暂时不可用，请稍后重试');
        const video={id:'one',title:input.query||'第一条',subtitle:input.folder||'root',source:'fixture',overview:''};
        if(input.folder)return {items:[{...video,id:'child',title:'目录内容'}]};
        if(input.page==='2')return {items:[video,{...video,id:'two',title:'第二页'}]};
        return {items:[video,{...video,id:'folder',reference:'owned-folder',kind:'folder',title:'目录'}],next:'2'};
      }};
      """
      try Data(code.utf8).write(to: source.appendingPathComponent("plugin.js"))
      let review = try await PluginClient.packages.prepare(directory: source)
      _ = try await PluginClient.packages.approve(review.id)
      await model.reloadPluginCatalog()
      guard let plugin = model.plugins.first(where: { $0.id == id }) else { throw MTVError.message("恢复测试包未加载") }
      model.openModule(plugin); await wait()
      let initial = readyTime()
      model.search = "保留原搜索"
      model.loadModule(action: "search", input: ["query": model.search, "readyAfter": initial])
      await wait()
      checks["moduleFailureIsInlineWithRemoteRetryFocus"] = model.moduleLoadFailure != nil && model.notice == nil
        && model.online.isEmpty && model.moduleHasFooter && model.focus.row == 2 && model.focus.column == 0
      await settle(); capture(window, to: output.appendingPathComponent("module-initial-error.png"))
      await waitUntil(initial)
      model.handle(.select); await wait()
      checks["moduleRetryPreservesSearchActionAndInput"] = model.moduleLoadFailure == nil && model.online.first?.title == "保留原搜索"
        && model.search == "保留原搜索" && model.moduleNextPage == "2"
      let parent = model.online.map(\.id)
      let more = readyTime()
      model.loadModule(action: "search", input: ["query": model.search, "page": "2", "readyAfter": more], append: true)
      await wait()
      checks["moduleAppendFailureKeepsLoadedPageAndCursor"] = model.online.map(\.id) == parent
        && model.moduleNextPage == "2" && model.moduleLoadFailure?.append == true
        && model.moduleLoadFailure?.input["page"] == "2" && model.notice == nil
      await settle(); capture(window, to: output.appendingPathComponent("module-more-error.png"))
      model.focus.select(row: 2, column: 1); model.handle(.select); await wait()
      checks["moduleAppendErrorDoesNotBlockLoadedFolder"] = model.moduleLoadFailure == nil
        && model.modulePath.last?.reference == "owned-folder" && model.online.first?.id == "child"
      model.handle(.back)
      checks["moduleBackRestoresParentRetryContext"] = model.modulePath.isEmpty && model.online.map(\.id) == parent
        && model.moduleLoadFailure?.input["page"] == "2" && model.moduleNextPage == "2"
      await waitUntil(more)
      model.focus.select(row: 2 + model.mediaRows.count, column: 0); model.handle(.select); await wait()
      checks["moduleAppendRetryContinuesAndDeduplicates"] = model.moduleLoadFailure == nil
        && model.online.map(\.id) == ["one", "folder", "two"] && model.moduleNextPage == nil
      model.focus.select(row: 2, column: 1); model.handle(.select); await wait()
      let folder = readyTime()
      model.loadModule(input: ["readyAfter": folder]); await wait()
      checks["moduleFolderFailureRetainsItsRoute"] = model.modulePath.last?.reference == "owned-folder"
        && model.moduleLoadFailure?.input["folder"] == "owned-folder" && model.focus.row == 2
      await waitUntil(folder)
      model.handle(.select); await wait()
      checks["moduleFolderRetryUsesSameFolder"] = model.moduleLoadFailure == nil
        && model.modulePath.count == 1 && model.online.first?.id == "child"
      model.loadModule(input: ["slow": "1", "fail": "1"])
      for _ in 0..<20 {
        if !PluginClient.runningProcessIDs(pluginID: id).isEmpty { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      let running = PluginClient.runningProcessIDs(pluginID: id)
      model.handle(.back)
      checks["moduleBackCancelsActuallyRunningRequest"] = !running.isEmpty && model.modulePath.isEmpty && !model.loading
      try? await Task.sleep(for: .milliseconds(2300))
      checks["moduleCancelledFailureCannotReplaceParent"] = model.moduleLoadFailure == nil
        && model.online.map(\.id) == ["one", "folder", "two"] && PluginClient.runningProcessIDs(pluginID: id).isEmpty
      model.loadModule(input: ["fail": "1"]); await wait()
      model.navigate(.home); model.retryModuleLoad()
      checks["moduleNavigationDiscardsFailureAndCannotRetryOldModule"] = model.section == .home
        && model.moduleLoadFailure == nil && !model.loading
    } catch { checks["moduleRecoveryFixtureExecution"] = false }
    model.quiescePlugin(id)
    do { try await PluginClient.packages.remove(id); await model.reloadPluginCatalog()
      checks["moduleRecoveryTemporaryPackageRemoved"] = !model.plugins.contains { $0.id == id }
    } catch { checks["moduleRecoveryTemporaryPackageRemoved"] = false }
    model.notice = nil; model.navigate(.home)
    return checks
  }
}

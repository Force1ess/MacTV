import Foundation
import MTVCore

extension UISmoke {
  static func bilibiliAccountSmoke(model: AppModel, output: URL) async -> [String: Bool] {
    guard CommandLine.arguments.contains("--live-services"), let plugin = model.plugins.first(where: { $0.id == "mtv.bilibili" }) else { return ["accountCheckRequiresExplicitLiveService": false] }
    var checks: [String: Bool] = [:], observations: [String: Any] = [:]
    do {
      guard let session = try PluginSessionStore().load(pluginID: plugin.id) else { throw MTVError.message("未保存B站登录，请在应用账号中扫码登录") }
      try session.validate(for: plugin.manifest)
      checks["bilibiliOwnSavedSessionLoadsWithoutPrompt"] = true
      for channel in BilibiliChannel.allCases {
        do {
          let data = try await PluginClient.execute(plugin, action: "browse", input: ["channel": channel.rawValue], sessionAccess: .stored)
          let page = try JSONDecoder().decode(PluginPage.self, from: data)
          _ = try PluginContentValidator.normalize(page.items, manifest: plugin.manifest)
          checks["bilibiliOwnAccount-" + channel.rawValue] = page.requiresLogin != true
          observations[channel.rawValue] = ["count": page.items.count, "requiresLogin": page.requiresLogin == true]
        } catch {
          checks["bilibiliOwnAccount-" + channel.rawValue] = false
          observations[channel.rawValue] = ["error": error.localizedDescription]
        }
      }
    } catch {
      checks["bilibiliOwnSavedSessionLoadsWithoutPrompt"] = false
      observations["accountError"] = error.localizedDescription
    }
    if let data = try? JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("bilibili-own-account-observations.json"))
    }
    return checks
  }
}

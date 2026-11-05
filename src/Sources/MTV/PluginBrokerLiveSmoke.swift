import Foundation
import MTVCore

extension UISmoke {
  static func pluginBrokerLiveSmoke(model: AppModel) async -> [String: Bool] {
    guard CommandLine.arguments.contains("--live-services") else { return ["brokerLiveServicesExplicitlyRequested": false] }
    var checks = ["brokerLiveServicesExplicitlyRequested": true]
    for id in ["mtv.bilibili", "mtv.quark"] {
      guard let plugin = model.plugins.first(where: { $0.id == id }) else { checks[id + "Challenge"] = false; continue }
      do {
        let execution = try await PluginClient.executeWithSession(plugin, action: "login", input: ["step": "start"], sessionAccess: .guest)
        let challenge = try JSONDecoder().decode(PluginLoginResponse.self, from: execution.data)
        try challenge.validateChallenge(for: plugin.manifest)
        checks[id + "ChallengeThroughBroker"] = challenge.state == "waiting" && challenge.qrURL != nil
        checks[id + "NoAccountSessionCreatedByChallenge"] = execution.session == nil
        // No QR image, URL, token, response body or cookie is written to diagnostics.
      } catch { checks[id + "ChallengeThroughBroker"] = false }
    }
    return checks
  }
}

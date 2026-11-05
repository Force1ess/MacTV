import Foundation

/// POST is opt-in for exact endpoints bundled and reviewed with the plugin.
public struct PluginPOSTEndpoint: Codable {
  public var host: String
  public var path: String
  public func validate(domains: [String]) throws {
    guard domains.contains(host), path.hasPrefix("/"), !path.contains(".."),
      !path.contains("?"), !path.contains("#"), !path.contains("%"), !path.contains("\\"),
      !path.contains("//"), path.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value < 127 })
    else { throw MTVError.message("插件 POST 端点声明无效") }
  }
  public func permits(_ url: URL) -> Bool {
    NetworkPolicy.permits(url, domains: [host]) && url.path == path && url.standardized.path == path
  }
}

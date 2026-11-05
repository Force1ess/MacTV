import Foundation

public enum FirstPartyMediaScope {
  public static let quarkHost = "video-play-c-sz.drive.quark.cn"
  public static let quarkHosts: Set<String> = [quarkHost, "video-play-c-zb.drive.quark.cn"]
  public static func isQuarkPlaybackHost(_ host: String) -> Bool {
    host.range(of: #"^(?:video-play|dl-pc)(?:-[a-z0-9]+)+\.drive\.quark\.cn$"#, options: .regularExpression) != nil
  }
}

/// Stores only host approval, never a session or playback URL.
public struct MediaSessionApprovalStore {
  private let defaults: UserDefaults
  private let key = "mtv.native-media-session.approved-scopes.v1"
  private let serviceKey = "mtv.native-media-session.quark-playback.v1"
  public init(defaults: UserDefaults = .standard) { self.defaults = defaults }
  private func scope(pluginID: String, host: String) -> String? {
    guard pluginID.range(of: #"^[a-z0-9]+([.-][a-z0-9]+)*$"#, options: .regularExpression) != nil,
      host == host.lowercased(), host.count <= 253,
      host.range(of: #"^[a-z0-9]+(?:[.-][a-z0-9]+)*\.[a-z0-9]+$"#, options: .regularExpression) != nil else { return nil }
    return pluginID + "@" + host
  }
  public func permits(pluginID: String, host: String) -> Bool {
    if pluginID == "mtv.quark", FirstPartyMediaScope.isQuarkPlaybackHost(host), defaults.bool(forKey: serviceKey) { return true }
    guard let value = scope(pluginID: pluginID, host: host) else { return false }
    return (defaults.stringArray(forKey: key) ?? []).contains(value)
  }
  public func approve(pluginID: String, host: String) throws {
    guard let value = scope(pluginID: pluginID, host: host) else { throw MTVError.message("播放会话批准范围无效") }
    var values = Set(defaults.stringArray(forKey: key) ?? [])
    guard values.count < 128 || values.contains(value) else { throw MTVError.message("播放会话批准数量超过限制") }
    values.insert(value); defaults.set(values.sorted(), forKey: key)
  }
  public func approveQuarkPlaybackService() { defaults.set(true, forKey: serviceKey) }
  public var quarkPlaybackServiceApproved: Bool { defaults.bool(forKey: serviceKey) }
  public func revoke(pluginID: String, host: String) {
    guard let value = scope(pluginID: pluginID, host: host) else { return }
    let values = (defaults.stringArray(forKey: key) ?? []).filter { $0 != value }
    defaults.set(values, forKey: key)
  }
  public func revokeAll(pluginID: String) {
    guard pluginID.range(of: #"^[a-z0-9]+([.-][a-z0-9]+)*$"#, options: .regularExpression) != nil else { return }
    let prefix = pluginID + "@"
    defaults.set((defaults.stringArray(forKey: key) ?? []).filter { !$0.hasPrefix(prefix) }, forKey: key)
    if pluginID == "mtv.quark" { defaults.removeObject(forKey: serviceKey) }
  }
}

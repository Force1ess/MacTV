import Foundation

public struct PluginRegistryRecoveryReview: Sendable {
  let registry: URL
  let snapshot: Data
  public let reason: String
  public var byteCount: Int { snapshot.count }
  public func writeBackup(in directory: URL) throws -> PluginRegistryRecoveryBackup {
    PluginRegistryRecoveryBackup(registry: registry, file: try .write(snapshot, in: directory,
      label: "插件清单", prefix: "plugin-registry-", suffix: ".json"))
  }
}
public struct PluginRegistryRecoveryBackup: Sendable {
  let registry: URL
  let file: PrivateDataBackup
  public var url: URL { file.url }
}

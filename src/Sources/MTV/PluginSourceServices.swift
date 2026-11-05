import Foundation
import MTVCore

enum PluginSourceServices {
  private struct Defaults: Decodable { let schemaVersion: Int; let defaultSources: [PluginSource] }
  static let configuration: Result<[PluginSource],Error> = Result {
    guard let root=Bundle.main.resourceURL else { throw MTVError.message(L("Plugin source configuration is missing.")) }
    let data=try Data(contentsOf:root.appendingPathComponent("plugin-sources.json"))
    let config=try JSONDecoder().decode(Defaults.self,from:data)
    guard config.schemaVersion==2, config.defaultSources.count<=32 else { throw MTVError.message(L("Invalid plugin source defaults.")) }
    for source in config.defaultSources { try source.validate() }; return config.defaultSources
  }
  static let store=PluginSourceStore(defaults:(try? configuration.get()) ?? [])
  static let client=PluginSourceClient.shared
  static func bundledCatalog(for source: PluginSource) -> PluginSourceCatalog? {
    guard (try? configuration.get().contains(where:{$0.repository==source.repository})) == true,
      let url=Bundle.main.resourceURL?.appendingPathComponent("plugin-catalog.json"),
      let data=try? Data(contentsOf:url) else { return nil }
    return try? PluginSourceCatalog(data:data)
  }
  static func prepare(_ entry: PluginSourceEntry, source: PluginSource, bundled: Bool, revision: String? = nil) async throws -> PluginInstallReview {
    _ = try configuration.get()
    guard try await store.sources().contains(where:{$0.id==source.id && $0.enabled && $0.repository==source.repository && $0.reference==source.reference}) else { throw MTVError.message(L("This source was removed or disabled.")) }
    if bundled {
      guard bundledCatalog(for:source)?.plugins.contains(entry)==true,
        let root=Bundle.main.resourceURL?.appendingPathComponent("ExamplePlugins"),
        let plugin=try PluginCatalog.load(root:root).plugins.first(where:{$0.id==entry.id && $0.manifest.version==entry.version}) else { throw MTVError.message(L("This plugin is not in the bundled catalog.")) }
      return try await PluginClient.packages.prepare(directory:plugin.directory,origin:PluginInstallationOrigin(kind:"bundled",source:source))
    }
    guard let revision else { throw MTVError.message(L("Refresh the Git catalog before selecting a plugin.")) }
    let parent=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/PluginDownloads")
    try FileManager.default.createDirectory(at:parent,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    let directory=parent.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:directory) }
    _ = try await client.stage(entry,source:source,revision:revision,into:directory)
    try Task.checkCancellation()
    guard try await store.sources().contains(where:{$0.id==source.id && $0.enabled && $0.repository==source.repository && $0.reference==source.reference}) else { throw MTVError.message(L("This source was removed or disabled.")) }
    return try await PluginClient.packages.prepare(directory:directory,origin:PluginInstallationOrigin(kind:"git",source:source,revision:revision))
  }
}

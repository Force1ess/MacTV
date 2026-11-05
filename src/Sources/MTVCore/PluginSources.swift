import Foundation

public struct PluginSource: Codable, Identifiable, Equatable, Sendable {
  public let id: String
  public var name: String
  public let repository: String
  public var reference: String
  public var enabled: Bool
  public init(id: String, name: String, repository: String, reference: String = "main", enabled: Bool = true) {
    self.id=id; self.name=name; self.repository=repository; self.reference=reference; self.enabled=enabled
  }
  public func validate() throws { try validate(localRoot:nil) }
  func validate(localRoot: URL?) throws {
    guard id.range(of:#"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#,options:.regularExpression) != nil,
      !name.isEmpty, name.count<=120, name.unicodeScalars.allSatisfy({$0.value>=32 && $0.value != 127}),
      Self.validReference(reference) else { throw MTVError.message(L("Invalid plugin source or branch.")) }
    if let localRoot, let url=URL(string:repository), url.isFileURL {
      let canonical=url.resolvingSymlinksInPath().standardizedFileURL
      guard canonical.path.hasPrefix(localRoot.resolvingSymlinksInPath().standardizedFileURL.path+"/") else { throw MTVError.message("Test repository escaped its fixture root") }
      return
    }
    guard Self.permits(repository) else { throw MTVError.message(L("Use an HTTPS, SSH or local Git repository URL without embedded passwords.")) }
  }
  public static func permits(_ value: String) -> Bool {
    guard value.utf8.count<=2048, value.unicodeScalars.allSatisfy({$0.value>32 && $0.value<127}) else { return false }
    if value.range(of:#"^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9.-]*:[A-Za-z0-9_][A-Za-z0-9._/-]*$"#,options:.regularExpression) != nil { return !value.split(separator:":",maxSplits:1)[1].split(separator:"/").contains("..") }
    if let url=URL(string:value), url.isFileURL {
      return (url.host==nil || url.host=="" || url.host=="localhost") && url.user==nil && url.password==nil && url.query==nil && url.fragment==nil && url.path.hasPrefix("/") && url.path != "/"
    }
    guard let url=URL(string:value), ["https","ssh"].contains(url.scheme), url.host != nil,
      url.password==nil, url.query==nil, url.fragment==nil, !url.path.isEmpty,
      url.scheme != "https" || url.user==nil, !url.path.split(separator:"/").contains("..") else { return false }
    return true
  }
  public static func validReference(_ value: String) -> Bool {
    value.range(of:#"^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$"#,options:.regularExpression) != nil && !value.contains("..") && !value.contains("//") && !value.hasSuffix("/")
  }
}

public struct PluginSourceEntry: Codable, Identifiable, Equatable, Sendable {
  public let id: String
  public let name: String
  public let version: String
  public let apiVersion: Int
  public let directory: String
  public let localizedNames: [String:String]?
  public var displayName: String {
    let language=Bundle.main.preferredLocalizations.first ?? "en"
    return localizedNames?[language] ?? (language.hasPrefix("zh") ? localizedNames?["zh-Hans"]:nil) ?? name
  }
  public var isCompatible: Bool { [1,2].contains(apiVersion) }
  public func validate() throws {
    guard !id.isEmpty, !id.hasPrefix("mtv."), id != "local", id.utf8.count<=128,
      !name.isEmpty, name.count<=120, (1...100).contains(apiVersion), (localizedNames?.count ?? 0)<=8,
      localizedNames?.values.allSatisfy({!$0.isEmpty && $0.count<=120}) ?? true,
      version.range(of:#"^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$"#,options:.regularExpression) != nil,
      directory.isEmpty || (directory.range(of:#"^[A-Za-z0-9_][A-Za-z0-9._/-]{0,255}$"#,options:.regularExpression) != nil && !directory.hasSuffix("/") && !directory.split(separator:"/").contains(where:{[".","..",".git"].contains(String($0))})) else { throw MTVError.message(L("This catalog contains an unsupported plugin package.")) }
  }
}

public struct PluginSourceCatalog: Codable, Sendable {
  public let schemaVersion: Int
  public let id: String
  public let name: String
  public let plugins: [PluginSourceEntry]
  public init(data: Data) throws {
    guard data.count<=524_288 else { throw MTVError.message(L("The plugin catalog is too large.")) }
    self=try JSONDecoder().decode(Self.self,from:data)
    guard schemaVersion==2, !name.isEmpty, name.count<=120, plugins.count<=200,
      Set(plugins.map(\.id)).count==plugins.count else { throw MTVError.message(L("Invalid plugin catalog.")) }
    for plugin in plugins { try plugin.validate() }
  }
}

public actor PluginSourceStore {
  private struct Document: Codable { let schemaVersion: Int; var sources: [PluginSource] }
  public let root: URL
  private let defaults: [PluginSource]
  public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/PluginSources"), defaults: [PluginSource] = []) {
    self.root=root; self.defaults=defaults
  }
  public func sources() throws -> [PluginSource] {
    let file=root.appendingPathComponent("sources.json")
    if !FileManager.default.fileExists(atPath:file.path) {
      for source in defaults { try source.validate() }
      try save(defaults); return defaults
    }
    let data=try Data(contentsOf:file,options:.mappedIfSafe)
    guard data.count<=131_072 else { throw MTVError.message(L("The source list is too large.")) }
    let document=try JSONDecoder().decode(Document.self,from:data)
    guard document.schemaVersion==2, document.sources.count<=32,
      Set(document.sources.map(\.id)).count==document.sources.count,
      Set(document.sources.map(\.repository)).count==document.sources.count else { throw MTVError.message(L("Invalid plugin source list.")) }
    for source in document.sources { try source.validate() }; return document.sources
  }
  private func save(_ sources: [PluginSource]) throws {
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    let file=root.appendingPathComponent("sources.json")
    try JSONEncoder().encode(Document(schemaVersion:2,sources:sources)).write(to:file,options:.atomic)
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:file.path)
  }
  public func add(_ repository: String) throws -> PluginSource {
    var list=try sources()
    guard list.count<32, !list.contains(where:{$0.repository==repository}) else { throw MTVError.message(L("This source already exists or the source limit was reached.")) }
    let parsed=URL(string:repository)
    let basename=parsed?.isFileURL == true ? parsed!.lastPathComponent : String(repository.split(separator:"/").last ?? "")
    let host=parsed?.host ?? (repository.contains("@") ? repository.split(separator:"@").last?.split(separator:":").first.map(String.init):nil)
    let label=host.map { $0+" / "+basename } ?? basename
    let source=PluginSource(id:UUID().uuidString,name:String(label.prefix(120)),repository:repository)
    try source.validate(); list.append(source); try save(list); return source
  }
  public func setEnabled(_ id: String, _ enabled: Bool) throws {
    var list=try sources(); guard let i=list.firstIndex(where:{$0.id==id}) else { throw MTVError.message(L("Plugin source not found.")) }
    list[i].enabled=enabled; try save(list)
  }
  public func remove(_ id: String) throws { try save(sources().filter{$0.id != id}) }
  public func setReference(_ id: String, _ reference: String) throws {
    var list=try sources(); guard let i=list.firstIndex(where:{$0.id==id}), PluginSource.validReference(reference) else { throw MTVError.message(L("Invalid plugin source or branch.")) }
    list[i].reference=reference; try save(list)
  }
}

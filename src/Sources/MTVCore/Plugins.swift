import Foundation

public struct PluginPresentation: Codable {
  public var symbol: String?
  public var tint: String?
  public var summary: String?
  public var availability: String?
  public var developerOnly: Bool?
  public var showOnHome: Bool?
}

public extension PluginManifest {
  var displayName: String {
    let language = Bundle.main.preferredLocalizations.first ?? "en"
    return localizedNames?[language] ?? localizedNames?[language.hasPrefix("zh") ? "zh-Hans" : "en"] ?? name
  }
}

public struct PluginRecord: Identifiable {
  public var id: String { manifest.id }
  public let manifest: PluginManifest
  public let directory: URL
  public var title: String { manifest.displayName }
  public var isAvailable: Bool {
    manifest.presentation?.availability != "development" && manifest.capabilities.contains("browse")
  }
  public init(manifest: PluginManifest, directory: URL) {
    self.manifest = manifest
    self.directory = directory
  }
}

public struct PluginCatalog {
  public var plugins: [PluginRecord]
  public var issues: [String]
  public static func load(root: URL, developerMode: Bool = false) throws -> PluginCatalog {
    let root = root.resolvingSymlinksInPath().standardizedFileURL
    let folders = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
    var records: [PluginRecord] = []
    var issues: [String] = []
    var identifiers = Set<String>()
    for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      let directory = folder.resolvingSymlinksInPath().standardizedFileURL
      guard (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
        continue
      }
      do {
        guard directory.path.hasPrefix(root.path + "/") else {
          throw MTVError.message("插件目录越出允许范围")
        }
        let manifestURL = directory.appendingPathComponent("manifest.json")
          .resolvingSymlinksInPath()
        guard manifestURL.path.hasPrefix(directory.path + "/") else {
          throw MTVError.message("清单不能链接到外部文件")
        }
        let manifest = try JSONDecoder().decode(
          PluginManifest.self, from: Data(contentsOf: manifestURL))
        try manifest.validate()
        let entry = directory.appendingPathComponent(manifest.entry).resolvingSymlinksInPath()
        guard entry.path.hasPrefix(directory.path + "/"),
          FileManager.default.fileExists(atPath: entry.path)
        else {
          throw MTVError.message("插件入口不存在或越出允许范围")
        }
        guard identifiers.insert(manifest.id).inserted else {
          throw MTVError.message(L("插件标识重复：\(manifest.id)"))
        }
        if manifest.presentation?.developerOnly == true && !developerMode { continue }
        records.append(PluginRecord(manifest: manifest, directory: directory))
      } catch { issues.append("\(folder.lastPathComponent)：\(error.localizedDescription)") }
    }
    return PluginCatalog(plugins: records, issues: issues)
  }
}

public struct PlaybackQualityOption: Codable, Identifiable, Sendable {
  public let id: Int
  public let title: String
  public let available: Bool
  public let reason: String?
  public init(id: Int, title: String, available: Bool = true, reason: String? = nil) {
    self.id = id; self.title = title; self.available = available; self.reason = reason
  }
}
public struct PlaybackDescriptor: Decodable {
  public let url: String
  public let quality: Int?
  public let qualityTitle: String?
  public let qualities: [PlaybackQualityOption]?
  public let height: Int?
  public let bandwidth: Int?
  public let note: String?
  public let expiresAt: Double?
  public let headers: [String: String]?
  public let audioURL: String?
  public let transport: String?
  public let continuation: PluginContinuation?
  public let videoOwner: String?
  public let videoOverview: String?
}

public struct PluginPage: Decodable {
  public let items: [MediaItem]
  public let next: String?
  public let requiresLogin: Bool?
}

public enum PluginContentValidator {
  public static func normalize(_ items: [MediaItem], manifest: PluginManifest) throws -> [MediaItem]
  {
    try manifest.validate()
    guard items.count <= 200 else { throw MTVError.message("插件单页内容超过 200 条限制") }
    var identifiers = Set<String>()
    var result: [MediaItem] = []
    for var item in items {
      if let artwork = item.artworkReference {
        guard manifest.nativeLibraries?.contains("music") == true,
          artwork.range(of:#"^[0-9]{1,32}$"#,options:.regularExpression) != nil else { throw MTVError.message("Invalid native artwork reference") }
      }
      if item.kind == .photo || item.kind == .audio {
        let required = item.kind == .photo ? "pictures" : "music"
        guard (manifest.nativeLibraries?.contains(required) == true || (item.kind == .photo && manifest.nativeLibraries?.contains(where: { ["photos","quark-pictures"].contains($0) }) == true)), item.url == nil, item.poster == nil,
          (item.reference?.utf8.count ?? 0) > 0, (item.reference?.utf8.count ?? 0) <= 8192 else { throw MTVError.message("Native media requires a declared library and opaque reference") }
      }
      guard !item.isLibraryCollection else { throw MTVError.message("插件不能创建本地资料库集合") }
      item.localMetadata = nil
      item.metadataAttribution = nil
      if let collection = item.collectionReference {
        guard !item.isFolder, manifest.capabilities.contains("folders"),
          !collection.isEmpty, collection.utf8.count <= 512,
          collection.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 })
        else { throw MTVError.message("插件选集缺少授权或有效引用") }
      }
      if item.isFolder {
        guard manifest.capabilities.contains("folders"), item.url == nil,
          let reference = item.reference, !reference.isEmpty, reference.utf8.count <= (manifest.nativeLibraries == nil ? 512 : 8192),
          reference.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 })
        else { throw MTVError.message("插件文件夹缺少授权或有效引用") }
      }
      guard !item.id.isEmpty, item.id.count <= 256,
        !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw MTVError.message("插件返回了无效的内容标识或标题")
      }
      if let artwork = item.poster {
        guard let url = URL(string: artwork),
          NetworkPolicy.permitsPlayback(url, domains: manifest.artworkDomains ?? [])
        else {
          throw MTVError.message("插件返回了未授权的封面地址")
        }
      }
      item.source = manifest.id
      if identifiers.insert(item.id).inserted { result.append(item) }
    }
    return result
  }
}

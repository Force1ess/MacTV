import Foundation

public enum MediaKind: String, Codable, Sendable { case video, folder, series, season, versions, extras, photo, audio }

public struct MediaItem: Codable, Identifiable, Hashable, Sendable {
  public var id: String
  public var title: String
  public var subtitle: String
  public var overview: String
  public var poster: String?
  public var url: String?
  public var source: String
  public var reference: String?
  /// Optional folder containing parts/episodes; playback reference remains independent.
  public var collectionReference: String?
  public var kind: MediaKind?
  public var artworkReference: String?
  public var localMetadata: LocalMediaMetadata?
  public var metadataAttribution: String?
  public var addedAt: Date? = nil
  public var isFolder: Bool { kind == .folder }
  public var isLibraryCollection: Bool { kind == .series || kind == .season || kind == .versions || kind == .extras }
  public init(
    id: String, title: String, subtitle: String = "", overview: String = "", poster: String? = nil,
    url: String? = nil, source: String = "local", reference: String? = nil, kind: MediaKind? = nil,
    localMetadata: LocalMediaMetadata? = nil, metadataAttribution: String? = nil,
    collectionReference: String? = nil, artworkReference: String? = nil, addedAt: Date? = nil
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.overview = overview
    self.poster = poster
    self.url = url
    self.source = source
    self.reference = reference
    self.collectionReference = collectionReference
    self.artworkReference = artworkReference
    self.kind = kind
    self.localMetadata = localMetadata
    self.metadataAttribution = metadataAttribution
    self.addedAt = addedAt
  }
}

public struct PluginManifest: Codable {
  public var id: String
  public var name: String
  public var localizedNames: [String: String]? = nil
  public var version: String
  public var apiVersion: Int
  public var entry: String
  public var domains: [String]
  public var capabilities: [String]
  public var playbackDomains: [String]?
  public var artworkDomains: [String]?
  public var presentation: PluginPresentation?
  public var authentication: PluginAuthentication?
  public var postEndpoints: [PluginPOSTEndpoint]?
  public var requestReferer: String?
  public var requestUserAgent: String? = nil
  public var playbackReferer: String?
  public var applicationLaunch: PluginAppLaunch? = nil
  public var nativeLibraries: [String]? = nil
  public func validate() throws {
    if let nativeLibraries {
      guard !nativeLibraries.isEmpty, nativeLibraries.allSatisfy({ ["photos", "pictures", "music", "quark-pictures"].contains($0) }),
        capabilities.contains("library") else { throw MTVError.message("Invalid native library declaration") }
    }
    guard !capabilities.contains("library") || nativeLibraries != nil else { throw MTVError.message("Missing native library services") }
    if let applicationLaunch {
      try applicationLaunch.validate()
      guard capabilities.contains("launch") else { throw MTVError.message("Application launch requires the launch capability") }
    }
    guard !capabilities.contains("launch") || applicationLaunch != nil else { throw MTVError.message("Missing application-launch declaration") }
    if let requestUserAgent {
      guard (1...512).contains(requestUserAgent.utf8.count),
        requestUserAgent.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 })
      else { throw MTVError.message("插件 User-Agent 声明无效") }
    }
    guard id != "local" else { throw MTVError.message("local 是本地影片库的内部标识，插件不能使用") }
    if let playbackReferer {
      guard playbackReferer.utf8.count <= 2048, let url = URL(string: playbackReferer),
        url.scheme == "https", url.host != nil, url.user == nil, url.password == nil,
        url.port == nil || url.port == 443, url.query == nil, url.fragment == nil,
        playbackReferer.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value < 127 })
      else { throw MTVError.message("媒体 Referer 声明无效") }
    }
    for endpoint in postEndpoints ?? [] { try endpoint.validate(domains: domains) }
    if let requestReferer {
      guard let url = URL(string: requestReferer), NetworkPolicy.permits(url, domains: domains),
        url.query == nil, url.fragment == nil
      else { throw MTVError.message("插件 Referer 声明无效") }
    }
    guard [1,2].contains(apiVersion) else { throw MTVError.message("插件接口版本不兼容") }
    guard id.range(of: #"^[a-z0-9]+([.-][a-z0-9]+)*$"#, options: .regularExpression) != nil,
      !name.isEmpty, entry == "plugin.js"
    else { throw MTVError.message("无效的插件标识或入口") }
    guard
      domains.allSatisfy({
        !$0.isEmpty && !$0.contains("/") && !$0.contains(":") && !$0.contains("*")
      })
    else {
      throw MTVError.message("插件必须声明精确域名，不允许通配符")
    }
    guard
      capabilities.allSatisfy({ ["browse", "search", "resolve", "login", "folders", "history", "lookup", "watchlist", "continuation", "launch", "library"].contains($0) })
    else {
      throw MTVError.message("插件声明了当前接口不支持的能力")
    }
    guard !capabilities.contains("history") || capabilities.contains("resolve") else { throw MTVError.message("观看记录需要模块支持播放解析") }
    guard !capabilities.contains("lookup") || capabilities.contains("resolve") else { throw MTVError.message("编号打开需要模块支持播放解析") }
    guard !capabilities.contains("watchlist") || capabilities.contains("resolve") else { throw MTVError.message("待看片单需要模块支持播放解析") }
    guard !capabilities.contains("continuation") || (capabilities.contains("resolve") && capabilities.contains("folders")) else { throw MTVError.message("连续观看需要模块支持选集与播放解析") }
    guard
      ((playbackDomains ?? []) + (artworkDomains ?? [])).allSatisfy({ domain in
        domain == domain.lowercased()
          && domain.range(of: #"^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$"#, options: .regularExpression)
            != nil
          && domain.contains(".")
      })
    else { throw MTVError.message("无效的播放域名授权") }
    if let authentication {
      try authentication.ticketExchange?.validate(authentication: authentication)
      guard capabilities.contains("login"), !authentication.issuerDomains.isEmpty,
        !authentication.sessionDomains.isEmpty,
        !authentication.qrDomains.isEmpty,
        authentication.qrDomains.allSatisfy({ domain in
          domain == domain.lowercased() && domain.contains(".") && !domain.contains("/")
            && !domain.contains(":") && !domain.contains("*")
        }),
        Set(authentication.issuerDomains + authentication.sessionDomains).isSubset(
          of: Set(domains)),
        !authentication.requiredCookieNames.isEmpty,
        !authentication.challengePaths.isEmpty, !authentication.credentialPaths.isEmpty,
        (1...5).contains(authentication.successCodePath.count),
        authentication.successCodePath.allSatisfy({
          $0.range(of: #"^[A-Za-z0-9_]+$"#, options: .regularExpression) != nil
        }),
        Set(authentication.challengePaths).isDisjoint(with: Set(authentication.credentialPaths)),
        (authentication.challengePaths + authentication.credentialPaths).allSatisfy({
          $0.hasPrefix("/") && !$0.contains("?") && !$0.contains("#") && !$0.contains("..")
        }),
        Set(authentication.requiredCookieNames).isSubset(of: Set(authentication.cookieNames)),
        authentication.cookieNames.allSatisfy({
          $0.range(of: #"^[A-Za-z0-9_-]{1,80}$"#, options: .regularExpression) != nil
        })
      else {
        throw MTVError.message("插件账号声明不合法，授权域名必须包含在网络域名中")
      }
    }
  }
}

public enum MTVError: Error, LocalizedError {
  case message(String)
  /// Stable machine identifiers must not change with the interface language.
  case code(String)
  case rateLimited
  public func localizedDescription(in bundle: Bundle) -> String {
    switch self {
    case .message(let text): return LT(text, bundle: bundle)
    case .code(let identifier): return identifier
    case .rateLimited: return LT("元数据请求过于频繁，请稍后重试", bundle: bundle)
    }
  }
  public var errorDescription: String? { localizedDescription(in: .main) }
}

public enum NetworkPolicy {
  public static func permits(_ url: URL, domains: [String]) -> Bool {
    url.scheme == "https" && url.user == nil && url.password == nil
      && (url.port == nil || url.port == 443) && domains.contains(url.host?.lowercased() ?? "")
  }
  public static func permitsPlayback(_ url: URL, domains: [String]) -> Bool {
    guard url.scheme == "https", url.user == nil, url.password == nil,
      url.port == nil || url.port == 443, let host = url.host?.lowercased()
    else { return false }
    return domains.contains { host == $0 || host.hasSuffix("." + $0) }
  }
}

public struct FocusGrid {
  public private(set) var row = 0
  public private(set) var column = 0
  public var rows: [Int]
  public init(rows: [Int]) { self.rows = rows }
  public mutating func select(row: Int, column: Int) {
    guard !rows.isEmpty else {
      self.row = 0
      self.column = 0
      return
    }
    self.row = min(max(0, row), rows.count - 1)
    self.column = min(max(0, column), max(0, rows[self.row] - 1))
  }
  public mutating func move(dx: Int, dy: Int) { select(row: row + dy, column: column + dx) }
}

public enum KeyboardLayout {
  public static let rows: [[String]] = [
    "QWERTYUIOP".map { String($0) }, "ASDFGHJKL".map { String($0) },
    "ZXCVBNM".map { String($0) }, "1234567890".map { String($0) },
    [".", ":", "/", "-", "_", "@", "?", "&", "=", "#", "'"],
    ["中/英", "大小写", "符号", "空格", "退格", "清空", "完成"],
  ]
  public static let symbols: [[String]] = [
    ["!", "@", "#", "$", "%", "^", "&", "*", "(", ")"],
    ["-", "_", "=", "+", "[", "]", "{", "}", "\\", "|"],
    [";", ":", "'", "\"", ",", ".", "<", ">", "/", "?"],
    ["`", "~"], "1234567890".map(String.init),
  ]
}

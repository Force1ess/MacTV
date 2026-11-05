import Foundation
import LocalAuthentication
import Security

public struct PluginAuthentication: Codable {
  public var issuerDomains: [String]
  public var sessionDomains: [String]
  public var qrDomains: [String]
  public var cookieNames: [String]
  public var requiredCookieNames: [String]
  public var challengePaths: [String]
  public var credentialPaths: [String]
  public var successCodePath: [String]
  public var successCode: Int
  public var ticketExchange: PluginTicketExchange? = nil
}

/// Some platforms issue a one-time ticket before setting session cookies.
/// The ticket is redeemed by native code and never enters plugin JavaScript.
public struct PluginTicketExchange: Codable {
  public var sourcePath: String
  public var ticketPath: [String]
  public var endpoint: String
  public var ticketParameter: String
  public var fixedQuery: [String: String]
  public var confirmationBooleanPath: [String]

  public func validate(authentication: PluginAuthentication) throws {
    guard let url = URL(string: endpoint),
      NetworkPolicy.permits(url, domains: authentication.issuerDomains),
      url.query == nil, url.fragment == nil,
      authentication.credentialPaths.contains(sourcePath),
      authentication.credentialPaths.contains(url.path), sourcePath != url.path,
      (1...5).contains(ticketPath.count), (1...5).contains(confirmationBooleanPath.count),
      (ticketPath + confirmationBooleanPath + [ticketParameter] + Array(fixedQuery.keys))
        .allSatisfy({ $0.range(of: #"^[A-Za-z0-9_]{1,80}$"#, options: .regularExpression) != nil }),
      fixedQuery[ticketParameter] == nil, fixedQuery.count <= 8,
      fixedQuery.values.allSatisfy({ $0.count <= 256 })
    else { throw MTVError.message("票据兑换声明无效") }
  }

  public func requestURL(body: Data, source: URL, authentication: PluginAuthentication) throws
    -> URL?
  {
    try validate(authentication: authentication)
    guard source.path == sourcePath,
      NetworkPolicy.permits(source, domains: authentication.issuerDomains)
    else { return nil }
    let root = try JSONSerialization.jsonObject(with: body)
    guard let status = Self.value(root, path: authentication.successCodePath) as? NSNumber,
      CFGetTypeID(status) != CFBooleanGetTypeID(),
      status.doubleValue == Double(authentication.successCode)
    else { return nil }
    guard let ticket = Self.value(root, path: ticketPath) as? String else { return nil }
    guard !ticket.isEmpty, ticket.utf8.count <= 4096,
      ticket.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value < 127 })
    else { throw MTVError.message("平台登录票据格式无效") }
    var components = URLComponents(string: endpoint)!
    components.queryItems =
      fixedQuery.sorted { $0.key < $1.key }.map {
        URLQueryItem(name: $0.key, value: $0.value)
      } + [URLQueryItem(name: ticketParameter, value: ticket)]
    guard let url = components.url else { throw MTVError.message("无法构造票据兑换请求") }
    return url
  }

  static func value(_ root: Any, path: [String]) -> Any? {
    var cursor = root
    for field in path {
      guard let object = cursor as? [String: Any], let next = object[field] else { return nil }
      cursor = next
    }
    return cursor
  }
}

public enum LoginResponseSanitizer {
  public static func publicPayload(_ data: Data) throws -> Data {
    guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw MTVError.message("登录响应格式错误")
    }
    var safe = raw.filter {
      ["code", "message", "data", "ttl", "status", "success"].contains($0.key)
    }
    if let payload = raw["data"] as? [String: Any] {
      safe["data"] = payload.filter {
        ["code", "message", "timestamp", "status", "success"].contains($0.key)
      }
    } else {
      safe.removeValue(forKey: "data")
    }
    return try JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys])
  }
}

/// This value stays in the native broker. Never expose it to the JS request object or logs.
public struct PluginSession: Codable, Sendable {
  public let pluginID: String
  public let domains: [String]
  public let cookie: String
  public let expiresAt: Double?
  public let savedAt: Double
  public let cookieExpiries: [String: Double]?
  public private(set) var authIdentity: UUID?
  func withAuthIdentity() -> Self { var value = self; value.authIdentity = UUID(); return value }
  public init(pluginID: String, domains: [String], cookie: String, expiresAt: Double? = nil, cookieExpiries: [String: Double]? = nil, authIdentity: UUID? = UUID()) {
    self.pluginID = pluginID
    self.domains = domains
    self.cookie = cookie
    self.expiresAt = expiresAt
    self.cookieExpiries = cookieExpiries
    self.authIdentity = authIdentity
    savedAt = Date().timeIntervalSince1970
  }
  public func validate(for manifest: PluginManifest) throws {
    guard pluginID == manifest.id, let authentication = manifest.authentication,
      !domains.isEmpty, Set(domains).isSubset(of: Set(authentication.sessionDomains)),
      !cookie.isEmpty, cookie.utf8.count <= 16_000,
      cookie.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 })
    else {
      throw MTVError.message("模块会话的范围或格式不合法")
    }
    if let expiresAt, !expiresAt.isFinite || expiresAt <= Date().timeIntervalSince1970 {
      throw MTVError.message("模块会话已过期，请重新扫码登录")
    }
  }
  public func cookieHeader(for url: URL) -> String? {
    NetworkPolicy.permits(url, domains: domains) ? cookie : nil
  }
}

public struct PluginLoginResponse: Decodable {
  public let state: String
  public let message: String?
  public let qrURL: String?
  public let token: String?
  public let expiresAt: Double?
  public let displayName: String?
  public func validateChallenge(for manifest: PluginManifest) throws {
    guard state == "waiting", let qrURL, let url = URL(string: qrURL),
      NetworkPolicy.permits(url, domains: manifest.authentication?.qrDomains ?? []),
      let token, !token.isEmpty, token.count <= 2048,
      let expiresAt, expiresAt > Date().timeIntervalSince1970,
      expiresAt < Date().timeIntervalSince1970 + 1800
    else {
      throw MTVError.message("插件返回的二维码授权信息不合法")
    }
  }
}

/// Only addresses MTV's own generic-password service, never other apps' credentials.
public struct PluginSessionStore {
  private static let lock = NSRecursiveLock()
  private let service: String
  public init(service: String = "local.mtv.preview.plugin-session") { self.service = service }
  private var vault: LocalCredentialStore { LocalCredentialStore(service: service) }
  private func modeKey(_ pluginID: String) -> String {
    "mtv.session.enabled." + service + "." + pluginID
  }
  public func isConfigured(pluginID: String) -> Bool {
    UserDefaults.standard.bool(forKey: modeKey(pluginID))
  }
  public func load(pluginID: String) throws -> PluginSession? {
    Self.lock.lock(); defer { Self.lock.unlock() }
    guard isConfigured(pluginID: pluginID) else { return nil }
    guard let data = try vault.load(account: pluginID) else {
      return nil
    }
    let decoded = try JSONDecoder().decode(PluginSession.self, from: data)
    if decoded.authIdentity == nil {
      let identified = decoded.withAuthIdentity()
      try vault.save(JSONEncoder().encode(identified),account:pluginID)
      return identified
    }
    return decoded
  }
  public func save(_ session: PluginSession) throws {
    Self.lock.lock(); defer { Self.lock.unlock() }
    try vault.save(JSONEncoder().encode(session), account: session.pluginID)
    UserDefaults.standard.set(true, forKey: modeKey(session.pluginID))
  }
  public func remove(pluginID: String) throws {
    Self.lock.lock(); defer { Self.lock.unlock() }
    try vault.remove(account: pluginID)
    UserDefaults.standard.removeObject(forKey: modeKey(pluginID))
  }
  /// A late HTTP response must never restore an account after logout or replace
  /// a newer login/refresh. All production session mutations share this lock.
  public func replace(_ original: PluginSession, with refreshed: PluginSession) throws -> Bool {
    Self.lock.lock(); defer { Self.lock.unlock() }
    guard original.pluginID == refreshed.pluginID, original.domains == refreshed.domains,
      let current = try load(pluginID: original.pluginID), current.savedAt == original.savedAt,
      current.cookie == original.cookie, current.expiresAt == original.expiresAt else { return false }
    try save(refreshed); return true
  }
}

import Foundation
import LocalAuthentication
import Security

/// Exact service/account records created by MTV, with no interactive fallback.
public struct PrivateKeychain {
  public let service: String
  public init(service: String) { self.service = service }
  private func query(_ account: String) -> [String: Any] {
    let context = LAContext()
    context.interactionNotAllowed = true
    return [
      kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
      kSecAttrAccount as String: account, kSecUseAuthenticationContext as String: context,
    ]
  }
  public func load(account: String) throws -> Data? {
    var request = query(account)
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let status = try LegacyKeychainInteraction.perform(allowInteraction: false) {
      SecItemCopyMatching(request as CFDictionary, &value)
    }
    if status == errSecItemNotFound { return nil }
    guard status == errSecSuccess, let data = value as? Data else { throw error(status) }
    return data
  }
  public func save(_ data: Data, account: String) throws {
    throw MTVError.message("MTV已停用钥匙串保存，请使用本地账号存储")
  }
  public func remove(account: String) throws {
    let status = try LegacyKeychainInteraction.perform(allowInteraction: false) {
      SecItemDelete(query(account) as CFDictionary)
    }
    guard status == errSecSuccess || status == errSecItemNotFound else { throw error(status) }
  }
  private func error(_ status: OSStatus) -> MTVError {
    .message("旧版MTV账号记录无法无提示迁移（\(status)），请重新登录")
  }
}

public struct MetadataTokenStore {
  private let vault: LocalCredentialStore
  private let defaults: UserDefaults
  private var modeKey: String { "mtv.metadata.token.enabled." + vault.service }
  public init(service: String = "local.mtv.preview.metadata-token", defaults: UserDefaults = .standard, root: URL? = nil) {
    vault = root.map { LocalCredentialStore(service: service, root: $0) } ?? LocalCredentialStore(service: service)
    self.defaults = defaults
  }
  public var isConfigured: Bool { defaults.bool(forKey: modeKey) }
  public func load() throws -> String? {
    guard isConfigured else { return nil }
    guard let data = try vault.load(account: "tmdb"),
      let token = String(data: data, encoding: .utf8)
    else {
      throw MTVError.message("已配置的 TMDB 令牌不存在，请重新设置或移除")
    }
    return token
  }
  public func save(_ input: String) throws {
    let token = input.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !token.isEmpty, token.utf8.count <= 4096,
      token.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 })
    else { throw MTVError.message("访问令牌格式无效") }
    try vault.save(Data(token.utf8), account: "tmdb")
    defaults.set(true, forKey: modeKey)
  }
  public func remove() throws {
    try vault.remove(account: "tmdb")
    defaults.removeObject(forKey: modeKey)
  }
}

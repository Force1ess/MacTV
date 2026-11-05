import Foundation

public struct SMBProfile: Codable, Equatable, Identifiable {
  public let id: UUID
  public var address: String
  public var username: String
  public var guest: Bool
  public var rememberPassword: Bool
  public var reconnectOnNetworkReturn: Bool? = nil
  public var allowsAutomaticReconnect: Bool {
    reconnectOnNetworkReturn == true && (guest || rememberPassword)
  }
  public init(
    id: UUID = UUID(), address: String, username: String, guest: Bool, rememberPassword: Bool,
    reconnectOnNetworkReturn: Bool = false
  ) throws {
    self.id = id
    self.address = try Self.canonicalAddress(address)
    self.username = guest ? "" : username.trimmingCharacters(in: .whitespacesAndNewlines)
    self.guest = guest
    self.rememberPassword = guest ? false : rememberPassword
    self.reconnectOnNetworkReturn = reconnectOnNetworkReturn ? true : nil
    try validate()
  }
  public static func canonicalAddress(_ text: String) throws -> String {
    let location = try SMBLocation(text)
    var parts = URLComponents(url: location.shareURL, resolvingAgainstBaseURL: false)!
    parts.host = parts.host?.lowercased()
    parts.path +=
      location.subdirectory.isEmpty ? "" : "/" + location.subdirectory.joined(separator: "/")
    guard let result = parts.url?.absoluteString else { throw MTVError.message("NAS 地址无效") }
    return result
  }
  public var credentialScope: String {
    get throws {
      let location = try SMBLocation(address)
      var parts = URLComponents(url: location.shareURL, resolvingAgainstBaseURL: false)!
      parts.host = parts.host?.lowercased()
      guard let scope = parts.url?.absoluteString else { throw MTVError.message("NAS 凭据范围无效") }
      return scope
    }
  }
  public func sameAccount(as other: SMBProfile) -> Bool {
    guard let left = try? credentialScope, let right = try? other.credentialScope else {
      return false
    }
    return id == other.id && username == other.username && guest == other.guest && left == right
  }
  public func validate() throws {
    guard try Self.canonicalAddress(address) == address,
      username.utf8.count <= 256,
      username.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
      (guest && username.isEmpty && !rememberPassword) || (!guest && !username.isEmpty)
    else { throw MTVError.message("请检查 NAS 地址和账号，或明确选择访客访问") }
    guard reconnectOnNetworkReturn != true || guest || rememberPassword else {
      throw MTVError.message("网络恢复重连需要访客访问，或明确记住密码")
    }
  }
}

private struct SMBProfilesDocument: Codable {
  let schema: Int
  var profiles: [SMBProfile]
}
public actor SMBProfileStore {
  public let file: URL
  public init(
    file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/MTV/Library/smb-connections.json")
  ) { self.file = file }
  public func load() throws -> [SMBProfile] {
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 131_072 else {
      throw MTVError.message("NAS 连接配置超过大小限制")
    }
    let value = try JSONDecoder().decode(SMBProfilesDocument.self, from: Data(contentsOf: file))
    guard value.schema == 1, value.profiles.count <= 100,
      Set(value.profiles.map(\.id)).count == value.profiles.count
    else { throw MTVError.message("NAS 连接配置无效") }
    for profile in value.profiles { try profile.validate() }
    return value.profiles
  }
  @discardableResult public func upsert(_ profile: SMBProfile) throws -> [SMBProfile] {
    try profile.validate()
    var profiles = try load()
    if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
      profiles[index] = profile
    } else {
      profiles.append(profile)
    }
    try write(profiles)
    return profiles
  }
  @discardableResult public func remove(_ id: UUID) throws -> [SMBProfile] {
    let profiles = try load().filter { $0.id != id }
    try write(profiles)
    return profiles
  }
  private func write(_ profiles: [SMBProfile]) throws {
    let data = try JSONEncoder().encode(SMBProfilesDocument(schema: 1, profiles: profiles))
    guard profiles.count <= 100, data.count <= 131_072 else {
      throw MTVError.message("NAS 连接配置超过大小限制")
    }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}

struct SMBCredentialRecord: Codable {
  let profileID: UUID
  let scope: String
  let username: String
  let password: String
  init(password: String, profile: SMBProfile) throws {
    guard !profile.guest, profile.rememberPassword, !password.isEmpty, !password.contains("\0"),
      password.utf8.count <= 4096
    else { throw MTVError.message("请输入有效密码，或关闭记住密码") }
    try profile.validate()
    profileID = profile.id
    scope = try profile.credentialScope
    username = profile.username
    self.password = password
  }
  func password(for profile: SMBProfile) throws -> String {
    try profile.validate()
    guard !profile.guest, profile.rememberPassword, profileID == profile.id,
      scope == (try profile.credentialScope), username == profile.username,
      !password.isEmpty, !password.contains("\0"), password.utf8.count <= 4096
    else { throw MTVError.message("服务器、共享或账号已改变，请重新输入密码") }
    return password
  }
  func encodedData() throws -> Data {
    let data = try JSONEncoder().encode(self)
    guard data.count <= 16_384 else { throw MTVError.message("NAS 密码记录超过保存限制") }
    return data
  }
}
public struct SMBCredentialStore {
  private let vault: LocalCredentialStore
  public init(service: String = "local.mtv.preview.smb-credentials") {
    vault = LocalCredentialStore(service: service)
  }
  public func load(for profile: SMBProfile) throws -> String? {
    guard !profile.guest, profile.rememberPassword else { return nil }
    guard let data = try vault.load(account: profile.id.uuidString), data.count <= 16_384,
      let record = try? JSONDecoder().decode(SMBCredentialRecord.self, from: data)
    else { throw MTVError.message("保存的 NAS 密码不存在或无法读取，请重新输入") }
    return try record.password(for: profile)
  }
  public func save(_ password: String, for profile: SMBProfile) throws {
    let record = try SMBCredentialRecord(password: password, profile: profile)
    try vault.save(record.encodedData(), account: profile.id.uuidString)
  }
  public func remove(profileID: UUID) throws { try vault.remove(account: profileID.uuidString) }
}

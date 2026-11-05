import Foundation
import MTVCore
import Security
import SQLite3

enum LocalChromeQuark {
  private static let storageReadLock = NSLock()
  struct Profile: Sendable { let directory: URL; let title: String }
  static var chromeRoot: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome", isDirectory: true) }
  static func profiles() throws -> [Profile] {
    try FileManager.default.contentsOfDirectory(at: chromeRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
      .filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.range(of: #"^Profile [0-9]{1,4}$"#, options: .regularExpression) != nil }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .map { Profile(directory: $0, title: $0.lastPathComponent == "Default" ? "Chrome 默认资料" : "Chrome " + $0.lastPathComponent) }
  }
  /// Called only after an explicit in-app import/profile action. The SELECT
  /// restricts domains and cookie names before any encrypted value is unlocked.
  static func read(_ profile: Profile, provider: String = "mtv.quark", allowInteraction: Bool = false,
    operation: ChromeStorageReadOperation = ChromeStorageReadOperation()) throws -> PluginSession {
    let expected = try profiles()
    guard expected.contains(where: { $0.directory == profile.directory }) else { throw CocoaError(.fileReadNoPermission) }
    let boundary = try ScopedFileReader.canonicalPath(chromeRoot)
    let selected = try ScopedFileReader.canonicalPath(profile.directory)
    guard selected.hasPrefix(boundary + "/") else { throw CocoaError(.fileReadNoPermission) }
    let possible = [profile.directory.appendingPathComponent("Network/Cookies"), profile.directory.appendingPathComponent("Cookies")]
    guard let file = possible.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { throw MTVError.message("此Chrome资料还没有登录资料，请先在Chrome登录对应平台") }
    guard try ScopedFileReader.canonicalPath(file).hasPrefix(selected + "/") else { throw CocoaError(.fileReadNoPermission) }
    return try readDatabase(file, provider: provider, unlock: { try storagePassword(allowInteraction: allowInteraction, operation: operation) })
  }
  /// The app calls this only after profile/path checks; tests supply their own SQLite fixture.
  static func readDatabase(_ file: URL, provider: String = "mtv.quark", unlock: () throws -> Data = { try storagePassword() }) throws -> PluginSession {
    guard ["mtv.quark", "mtv.bilibili"].contains(provider) else { throw MTVError.message("不支持此平台") }
    var database: OpaquePointer?
    guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let database else {
      if let database { sqlite3_close(database) }
      throw MTVError.message("无法打开Chrome登录资料。请在这台Mac上允许MacTV访问Chrome资料后重试，或选择扫码登录。")
    }
    defer { sqlite3_close(database) }
    sqlite3_busy_timeout(database, 1000)
    var version = 0, meta: OpaquePointer?
    if sqlite3_prepare_v2(database, "SELECT value FROM meta WHERE key='version'", -1, &meta, nil) == SQLITE_OK,
      sqlite3_step(meta) == SQLITE_ROW { version = Int(sqlite3_column_int(meta, 0)) }
    sqlite3_finalize(meta)
    guard (23...24).contains(version) else { throw MTVError.message(L("暂不支持此Chrome资料版本（\(version)）。请更新MacTV或选择扫码登录。")) }
    let hosts = provider == "mtv.quark" ? "'.quark.cn','drive.quark.cn','.drive.quark.cn'" : "'.bilibili.com','api.bilibili.com','.api.bilibili.com'"
    let names = provider == "mtv.quark" ? "'__pus','__puus','__kps','__uid'" : "'SESSDATA','bili_jct','DedeUserID','DedeUserID__ckMd5'"
    let sql = "SELECT host_key,name,value,encrypted_value,path,expires_utc FROM cookies WHERE host_key IN (\(hosts)) AND name IN (\(names)) AND path='/' LIMIT 17"
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw MTVError.message("Chrome会话库结构尚不支持，请使用扫码登录") }
    defer { sqlite3_finalize(statement) }
    func text(_ column: Int32) -> String {
      guard let pointer = sqlite3_column_text(statement, column) else { return "" }; return String(cString: pointer)
    }
    struct Row { let host: String, name: String, clear: String; let encrypted: Data; let expiry: Double? }
    var rows: [Row] = []
    var step = sqlite3_step(statement)
    while step == SQLITE_ROW {
      defer { step = sqlite3_step(statement) }
      guard rows.count < 16 else { throw MTVError.message("Chrome平台会话存在冲突，请重新登录") }
      let host = text(0), name = text(1), clear = text(2), bytes = Int(sqlite3_column_bytes(statement, 3))
      let expiryRaw = sqlite3_column_int64(statement, 5)
      let expiry = expiryRaw > 0 ? Double(expiryRaw) / 1_000_000 - 11_644_473_600 : nil
      if let expiry, expiry <= Date().timeIntervalSince1970 { continue }
      guard bytes <= 32768 else { throw MTVError.message("Chrome会话过大") }
      let encrypted = bytes > 0 ? sqlite3_column_blob(statement, 3).map { Data(bytes: $0, count: bytes) } ?? Data() : Data()
      rows.append(Row(host: host, name: name, clear: clear, encrypted: encrypted, expiry: expiry))
    }
    guard step == SQLITE_DONE else { throw MTVError.message("Chrome资料正在更新，请稍后重试") }
    let required = provider == "mtv.quark" ? Set(["__pus", "__puus"]) : Set(["SESSDATA"])
    guard rows.contains(where: { required.contains($0.name) && (!$0.clear.isEmpty || !$0.encrypted.isEmpty) }) else {
      throw MTVError.message(provider == "mtv.quark" ? "这份Chrome资料没有有效的夸克登录。请先在这台Mac的Chrome登录夸克网盘，再导入。" : "这份Chrome资料没有有效的B站登录。请先在Chrome登录哔哩哔哩，再导入。")
    }
    var entries: [[String: Any]] = [], secret: Data?
    for row in rows {
      let value: String
      if !row.encrypted.isEmpty {
        guard row.clear.isEmpty else { throw MTVError.message("Chrome会话格式不一致") }
        if secret == nil { secret = try ChromeCookieCipher.key(password: unlock()) }
        value = try ChromeCookieCipher.decrypt(row.encrypted, key: secret!, host: row.host, databaseVersion: version)
      } else { value = row.clear }
      var entry: [String: Any] = ["name": row.name, "value": value, "domain": row.host, "path": "/", "hostOnly": !row.host.hasPrefix(".")]
      if let expiry = row.expiry { entry["expirationDate"] = expiry }
      entries.append(entry)
    }
    let data = try JSONSerialization.data(withJSONObject: ["schema": 1, "provider": provider, "cookies": entries])
    return try ChromePlatformSession.decode(data)
  }
  static func storagePassword(allowInteraction: Bool = false,
    operation: ChromeStorageReadOperation = ChromeStorageReadOperation()) throws -> Data {
    // One reader across platforms and retries. The login attempt can terminate
    // its helper; MTV itself never blocks in an uninterruptible keychain read.
    guard storageReadLock.try() else {
      throw MTVError.message("上一次 Chrome 系统授权仍在等待。请先完成或取消系统提示，再重试；也可以使用扫码登录。")
    }
    defer { storageReadLock.unlock() }
    return try ChromeStorageReader.read(allowInteraction: allowInteraction, operation: operation)
  }
}

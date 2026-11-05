import Darwin
import Foundation

/// Local records owned by the current macOS user. No Keychain writes or UI prompts.
/// Files are permission-protected, not encrypted against other processes of this user.
public struct LocalCredentialStore {
  public let service: String
  public let root: URL
  public init(service: String, root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Credentials")) {
    self.service = service; self.root = root
  }
  private func name(_ account: String) throws -> String {
    guard !service.isEmpty, !account.isEmpty, service.utf8.count + account.utf8.count <= 180,
      (service + account).unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { throw MTVError.message("本地账号标识无效") }
    return Data((service + "\n" + account).utf8).base64EncodedString()
      .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
  }
  private func directory() throws -> Int32 {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw MTVError.message("无法安全打开MTV本地账号目录") }
    var node = stat()
    guard fstat(directory, &node) == 0, node.st_uid == getuid(), fchmod(directory, 0o700) == 0 else {
      close(directory); throw MTVError.message("MTV本地账号目录权限不正确")
    }
    return directory
  }
  public func load(account: String) throws -> Data? {
    let name = try name(account), directory = try directory(); defer { close(directory) }
    let file = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    if file < 0 && errno == ENOENT { return nil }
    guard file >= 0 else { throw MTVError.message("无法安全读取MTV本地账号") }
    defer { close(file) }
    var node = stat()
    guard fstat(file, &node) == 0, node.st_uid == getuid(), node.st_mode & S_IFMT == S_IFREG,
      node.st_mode & 0o077 == 0, node.st_nlink == 1, node.st_size >= 0, node.st_size <= 65536 else {
      throw MTVError.message("MTV本地账号文件权限或大小异常")
    }
    var data = Data(count: Int(node.st_size))
    try data.withUnsafeMutableBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.read(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw MTVError.message("MTV本地账号未完整读取") }
        offset += count
      }
    }
    return data
  }
  public func save(_ data: Data, account: String) throws {
    guard data.count <= 65536 else { throw MTVError.message("MTV本地账号超过保存限制") }
    let name = try name(account), directory = try directory(); defer { close(directory) }
    let temporary = ".write-" + UUID().uuidString
    let file = openat(directory, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard file >= 0 else { throw MTVError.message("无法创建MTV本地账号文件") }
    defer { close(file); unlinkat(directory, temporary, 0) }
    try data.withUnsafeBytes { buffer in
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(file, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw MTVError.message("MTV本地账号未完整保存") }
        offset += count
      }
    }
    guard fsync(file) == 0, renameat(directory, temporary, directory, name) == 0, fsync(directory) == 0 else {
      throw MTVError.message("MTV本地账号未能保存到磁盘")
    }
  }
  public func remove(account: String) throws {
    let name = try name(account), directory = try directory(); defer { close(directory) }
    guard unlinkat(directory, name, 0) == 0 || errno == ENOENT else { throw MTVError.message("MTV本地账号未能移除") }
  }
}

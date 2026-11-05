import Darwin
import Foundation

/// Byte-for-byte private backup shared by explicitly reviewed recovery flows.
struct PrivateDataBackup: Sendable {
  let url: URL
  let snapshot: Data
  let device: Int64
  let inode: UInt64
  let label: String
  static func write(_ snapshot: Data, in directory: URL, label: String, prefix: String, suffix: String) throws -> Self {
    guard directory.isFileURL else { throw MTVError.message(L("\(LT(label))备份目录无效")) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard parent >= 0 else { throw MTVError.message(L("无法安全打开\(LT(label))备份目录")) }
    defer { close(parent) }
    let name = prefix + UUID().uuidString.lowercased() + suffix
    let file = openat(parent, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard file >= 0 else { throw MTVError.message(L("无法创建\(LT(label))备份；原数据未清除")) }
    defer { close(file) }
    try snapshot.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      var offset = 0
      while offset < buffer.count {
        let count = Darwin.write(file, base.advanced(by: offset), buffer.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw MTVError.message(L("\(LT(label))备份未完整写入；原数据未清除")) }
        offset += count
      }
    }
    guard fsync(file) == 0 else { throw MTVError.message(L("\(LT(label))备份未能同步到磁盘；原数据未清除")) }
    var node = stat()
    guard fstat(file, &node) == 0, node.st_size == snapshot.count else { throw MTVError.message(L("\(LT(label))备份校验失败")) }
    return Self(url: directory.appendingPathComponent(name), snapshot: snapshot,
      device: Int64(node.st_dev), inode: UInt64(node.st_ino), label: label)
  }
  func verify() throws {
    let file = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard file >= 0 else { throw MTVError.message(L("\(LT(label))备份已丢失或不可读；原数据未清除")) }
    defer { close(file) }
    var node = stat()
    guard fstat(file, &node) == 0, (node.st_mode & S_IFMT) == S_IFREG,
      Int64(node.st_dev) == device, UInt64(node.st_ino) == inode, node.st_size == snapshot.count else {
      throw MTVError.message(L("\(LT(label))备份已变化；原数据未清除"))
    }
    var data = Data(count: snapshot.count)
    try data.withUnsafeMutableBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      var offset = 0
      while offset < buffer.count {
        let count = read(file, base.advanced(by: offset), buffer.count - offset)
        if count < 0 && errno == EINTR { continue }
        guard count > 0 else { throw MTVError.message(L("\(LT(label))备份未完整读取")) }
        offset += count
      }
    }
    var after = stat()
    var named = stat()
    guard fstat(file, &after) == 0, after.st_size == node.st_size,
      after.st_nlink > 0, lstat(url.path, &named) == 0, (named.st_mode & S_IFMT) == S_IFREG,
      Int64(named.st_dev) == device, UInt64(named.st_ino) == inode,
      after.st_mtimespec.tv_sec == node.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == node.st_mtimespec.tv_nsec,
      after.st_ctimespec.tv_sec == node.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == node.st_ctimespec.tv_nsec,
      data == snapshot else { throw MTVError.message(L("\(LT(label))备份内容已变化；原数据未清除")) }
  }
}

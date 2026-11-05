import CryptoKit
import Foundation

/// Bounded, disposable artwork data. Keys hash the URL, never media file contents.
public actor ArtworkDiskStore {
  public let root: URL
  private let capacity: Int
  private let itemLimit: Int
  public init(
    root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Caches/MTV/Artwork"), capacity: Int = 300_000_000, itemLimit: Int = 15_000_000
  ) {
    self.root = root
    self.capacity = max(0, capacity)
    self.itemLimit = max(0, itemLimit)
  }
  private func file(_ url: URL) throws -> URL {
    guard (url.scheme == "https" && url.host != nil && url.user == nil && url.password == nil)
      || SMBCachedArtwork.isLocalReference(url) else {
      throw MTVError.message("图片缓存地址无效")
    }
    let key = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }
      .joined()
    return root.appendingPathComponent(key + ".image")
  }
  public func read(_ url: URL) throws -> Data? {
    let path = try file(url)
    guard FileManager.default.fileExists(atPath: path.path) else { return nil }
    let values = try path.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size > 0, size <= itemLimit
    else { return nil }
    let data = try Data(contentsOf: path)
    guard data.count <= itemLimit else { return nil }
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: path.path)
    return data
  }
  public func write(_ data: Data, for url: URL) throws {
    guard !data.isEmpty, data.count <= itemLimit, data.count <= capacity else {
      throw MTVError.message("图片超出缓存大小限制")
    }
    let path = try file(url)
    try FileManager.default.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try data.write(to: path, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    try trim()
  }
  public func remove(_ url: URL) throws {
    let path = try file(url)
    if FileManager.default.fileExists(atPath: path.path) {
      try FileManager.default.removeItem(at: path)
    }
  }
  private func trim() throws {
    let files = try FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
      ], options: [.skipsHiddenFiles])
    let entries = try files.compactMap { url -> (URL, Int, Date)? in
      guard
        url.lastPathComponent.range(of: #"^[0-9a-f]{64}\.image$"#, options: .regularExpression)
          != nil
      else { return nil }
      let values = try url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey,
      ])
      guard values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
      return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
    }.sorted { $0.2 < $1.2 }
    var size = entries.reduce(0) { $0 + $1.1 }
    for entry in entries where size > capacity {
      try FileManager.default.removeItem(at: entry.0)
      size -= entry.1
    }
  }
}

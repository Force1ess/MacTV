import Foundation
import CryptoKit

public struct LibraryIndexSnapshot: Codable {
  public let schema: Int
  public let sourcePath: String
  public let scannedAt: Date
  public let items: [MediaItem]
  public var incremental: LibraryIncrementalManifest? = nil
  public var incrementalState: LibraryIncrementalState? {
    incremental.map { LibraryIncrementalState(root: URL(fileURLWithPath: sourcePath), items: items, manifest: $0) }
  }
}

/// Derived read-only media descriptions. Never contains credentials or matched overlays.
public actor LibraryIndexStore {
  public let file: URL
  public init(
    file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/MTV/Library/index.json")
  ) { self.file = file }
  public func load(root: URL) throws -> LibraryIndexSnapshot? {
    let path = root.standardizedFileURL.path
    if let snapshot = try read(), snapshot.sourcePath == path { return snapshot }
    guard let archived = try read(at: archiveURL(path)), archived.sourcePath == path else { return nil }
    return archived
  }
  public func savedSourcePath() throws -> String? { try read()?.sourcePath }
  private func read() throws -> LibraryIndexSnapshot? {
    try read(at: file)
  }
  private var archiveRoot: URL { file.deletingPathExtension().appendingPathExtension("sources") }
  private func archiveURL(_ path: String) -> URL {
    let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    return archiveRoot.appendingPathComponent(key + ".json")
  }
  private func read(at location: URL) throws -> LibraryIndexSnapshot? {
    guard FileManager.default.fileExists(atPath: location.path) else { return nil }
    guard (try location.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 25_000_000 else {
      throw MTVError.message("影片索引超过大小限制")
    }
    let snapshot = try JSONDecoder().decode(LibraryIndexSnapshot.self, from: Data(contentsOf: location))
    try validate(snapshot)
    return snapshot
  }
  @discardableResult public func save(items: [MediaItem], root: URL, scannedAt: Date = Date(), incremental: LibraryIncrementalManifest? = nil)
    throws -> Bool
  {
    let snapshot = LibraryIndexSnapshot(
      schema: 1, sourcePath: root.standardizedFileURL.path,
      scannedAt: scannedAt, items: items, incremental: incremental)
    try validate(snapshot)
    // Late older writes must not replace a newer scan, even after a source switch.
    if let previous = try? read() {
      if previous.scannedAt > scannedAt { return false }
      if previous.sourcePath != snapshot.sourcePath {
        let target = archiveURL(previous.sourcePath)
        if !FileManager.default.fileExists(atPath: target.path) {
          let entries = (try? FileManager.default.contentsOfDirectory(at: archiveRoot,
            includingPropertiesForKeys: nil)) ?? []
          guard entries.count < 32 else { throw MTVError.message("来源索引缓存已满，旧索引已保留") }
        }
        let bytes = try JSONEncoder().encode(previous)
        try FileManager.default.createDirectory(at: archiveRoot, withIntermediateDirectories: true)
        try bytes.write(to: target, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
      }
    }
    let data = try JSONEncoder().encode(snapshot)
    guard data.count <= 25_000_000 else { throw MTVError.message("影片索引超过大小限制") }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return true
  }
  private func validate(_ snapshot: LibraryIndexSnapshot) throws {
    guard snapshot.schema == 1, snapshot.sourcePath.hasPrefix("/"),
      snapshot.sourcePath.utf8.count <= 4096, snapshot.items.count <= 10_000,
      Set(snapshot.items.map(\.id)).count == snapshot.items.count,
      snapshot.scannedAt.timeIntervalSince1970.isFinite
    else { throw MTVError.message("影片索引格式无效") }
    let root = URL(fileURLWithPath: snapshot.sourcePath).standardizedFileURL.path
    try snapshot.incremental?.validate(itemIDs: Set(snapshot.items.map(\.id)))
    guard root == snapshot.sourcePath else { throw MTVError.message("影片索引来源路径无效") }
    for item in snapshot.items {
      guard item.source == "local", !item.isFolder, !item.isLibraryCollection,
        item.id.hasPrefix(root == "/" ? "/" : root + "/"),
        let raw = item.url, let url = URL(string: raw), url.isFileURL,
        url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
        url.standardizedFileURL.path == item.id,
        item.title.count <= 4096, item.overview.utf8.count <= 2_000_000,
        item.metadataAttribution == nil
      else { throw MTVError.message("影片索引含不属于所选目录的条目") }
    }
  }
}

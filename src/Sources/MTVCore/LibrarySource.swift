import Foundation

public enum LibrarySourceOrigin: String, Codable, Sendable { case chosen, legacyPreference, existingIndex }
public struct LibrarySourceSelection: Codable, Equatable, Sendable {
  public let schema: Int
  public let path: String?
  public let origin: LibrarySourceOrigin
  public var smbProfileID: UUID? = nil
  public init(path: String?, origin: LibrarySourceOrigin = .chosen) {
    schema = 1
    self.path = path
    self.origin = origin
  }
  public func validate() throws {
    guard schema == 1 else { throw MTVError.message("来源配置版本不兼容") }
    guard path == nil || smbProfileID == nil else { throw MTVError.message("来源配置不能同时包含本地和 NAS") }
    if let path {
      guard path.hasPrefix("/"), !path.contains("\0"), path.utf8.count <= 4096,
        URL(fileURLWithPath: path).standardizedFileURL.path == path
      else { throw MTVError.message("来源目录路径无效，请重新选择") }
    }
  }
  public init(smbProfileID: UUID) {
    schema = 1; path = nil; origin = .chosen; self.smbProfileID = smbProfileID
  }
}

public actor LibrarySourceStore {
  public static var normalFile: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/MTV/Library/source.json")
  }
  public let file: URL
  public init(file: URL = LibrarySourceStore.normalFile) { self.file = file }
  public func load() throws -> LibrarySourceSelection? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 16_384 else {
      throw MTVError.message("来源配置大小异常")
    }
    let selection = try JSONDecoder().decode(
      LibrarySourceSelection.self, from: Data(contentsOf: file))
    try selection.validate()
    return selection
  }
  public func save(_ selection: LibrarySourceSelection) throws {
    try selection.validate()
    let data = try JSONEncoder().encode(selection)
    guard data.count <= 16_384 else { throw MTVError.message("来源配置超过大小限制") }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
  public func resolve(legacyPath: String?, index: LibraryIndexStore) async throws
    -> LibrarySourceSelection?
  {
    if let saved = try load() { return saved }
    if let legacyPath {
      let selection = LibrarySourceSelection(path: legacyPath, origin: .legacyPreference)
      try save(selection)
      return selection
    }
    let previous = try await index.savedSourcePath()
    // An explicit choice made during the await always wins over migration.
    if let saved = try load() { return saved }
    guard let previous else { return nil }
    let selection = LibrarySourceSelection(path: previous, origin: .existingIndex)
    try save(selection)
    return selection
  }
}

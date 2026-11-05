import Foundation

public struct SavedLibrarySource: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var title: String
  public let path: String?
  public let smbProfileID: UUID?
  public var selection: LibrarySourceSelection {
    if let smbProfileID { return LibrarySourceSelection(smbProfileID: smbProfileID) }
    return LibrarySourceSelection(path: path)
  }
  public func matches(_ selection: LibrarySourceSelection) -> Bool {
    path == selection.path && smbProfileID == selection.smbProfileID
  }
  public func validate() throws {
    try selection.validate()
    guard (path == nil) != (smbProfileID == nil), !title.isEmpty,
      title.utf8.count <= 1024,
      title.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 })
    else { throw MTVError.message("已保存来源格式无效") }
  }
}

private struct SavedSourcesDocument: Codable {
  let schema: Int
  var sources: [SavedLibrarySource]
}

public actor SavedLibrarySourcesStore {
  public let file: URL
  public init(file: URL) { self.file = file }
  public func load() throws -> [SavedLibrarySource] {
    guard FileManager.default.fileExists(atPath: file.path) else { return [] }
    guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 262_144 else {
      throw MTVError.message("已保存来源超过大小限制")
    }
    let document = try JSONDecoder().decode(SavedSourcesDocument.self, from: Data(contentsOf: file))
    guard document.schema == 1, document.sources.count <= 32,
      Set(document.sources.map(\.id)).count == document.sources.count
    else { throw MTVError.message("已保存来源格式无效") }
    for (index, source) in document.sources.enumerated() {
      try source.validate()
      guard !document.sources.prefix(index).contains(where: { $0.matches(source.selection) }) else {
        throw MTVError.message("已保存来源包含重复目录")
      }
    }
    return document.sources
  }
  @discardableResult public func remember(_ selection: LibrarySourceSelection, title: String) throws -> [SavedLibrarySource] {
    try selection.validate()
    guard selection.path != nil || selection.smbProfileID != nil else { return try load() }
    var values = try load()
    let existing = values.firstIndex { $0.matches(selection) }
    let record = SavedLibrarySource(id: existing.map { values[$0].id } ?? UUID(), title: title,
      path: selection.path, smbProfileID: selection.smbProfileID)
    try record.validate()
    if let existing { values[existing] = record }
    else {
      guard values.count < 32 else { throw MTVError.message("最多保存 32 个来源，请先移除不用的来源") }
      values.append(record)
    }
    try write(values)
    return values
  }
  public func remove(_ id: UUID) throws -> [SavedLibrarySource] {
    var values = try load()
    values.removeAll { $0.id == id }
    try write(values)
    return values
  }
  private func write(_ values: [SavedLibrarySource]) throws {
    let bytes = try JSONEncoder().encode(SavedSourcesDocument(schema: 1, sources: values))
    guard bytes.count <= 262_144 else { throw MTVError.message("已保存来源超过大小限制") }
    try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }
}

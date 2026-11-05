import Darwin
import Foundation

public struct SMBDirectorySelection: Sendable {
  public let directory: URL
  /// Canonical, share-relative path; empty for the share root.
  public let relativePath: String
}

public enum SMBDirectoryAccess {
  /// May perform network filesystem I/O; callers must run this off the UI actor.
  public static func selection(in url: URL, allowedRoot: URL) throws -> SMBDirectorySelection {
    let root = allowedRoot.resolvingSymlinksInPath().standardizedFileURL
    let folder = url.resolvingSymlinksInPath().standardizedFileURL
    guard folder.path == root.path || folder.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else {
      throw MTVError.message("所选目录超出共享范围")
    }
    try requireDirectory(root)
    try requireDirectory(folder)
    let relative = folder.path == root.path ? "" : (root.path == "/" ? folder.path : String(folder.path.dropFirst(root.path.count)))
    return SMBDirectorySelection(directory: folder, relativePath: relative)
  }
  public static func children(in url: URL, allowedRoot: URL) throws -> (directory: URL, folders: [URL]) {
    let root = allowedRoot.resolvingSymlinksInPath().standardizedFileURL
    let folder = url.resolvingSymlinksInPath().standardizedFileURL
    func inside(_ value: URL) -> Bool { value.path == root.path || value.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") }
    guard inside(folder) else { throw MTVError.message("此目录超出共享范围") }
    do {
      let contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
      let directories = contents.filter { inside($0.resolvingSymlinksInPath().standardizedFileURL) && (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
      return (folder, Array(directories.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }.prefix(200)))
    } catch { throw SMBFailure(error, stage: .directoryRead) }
  }
  /// Preserve real filesystem errors instead of conflating missing and denied.
  public static func requireDirectory(_ directory: URL) throws {
    do {
      let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
      guard let isDirectory = values.isDirectory else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
      guard isDirectory else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOTDIR)) }
    } catch { throw SMBFailure(error, stage: .directoryVerification) }
  }
}

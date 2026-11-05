import Foundation

public struct LocalFolderListing {
  public let directory: URL
  public let folders: [URL]
  public let total: Int
}

public enum LocalFolders {
  public static func address(_ text: String) throws -> URL {
    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, text.utf8.count <= 4096, !text.contains("\0"),
      text.hasPrefix("/") || text == "~" || text.hasPrefix("~/")
    else { throw MTVError.message("请输入绝对目录路径，例如 ~/Movies 或 /Volumes/影片") }
    return URL(fileURLWithPath: (text as NSString).expandingTildeInPath, isDirectory: true)
      .standardizedFileURL
  }
  public static func list(_ url: URL, limit: Int = 200) throws -> LocalFolderListing {
    guard url.isFileURL, limit > 0, limit <= 1000 else { throw MTVError.message("目录参数无效") }
    let directory = url.standardizedFileURL
    let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
    guard values.isDirectory == true else { throw MTVError.message("请选择文件夹，不能选择单个文件") }
    let entries = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
      options: [.skipsHiddenFiles])
    let folders = entries.filter {
      guard let values = try? $0.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]) else {
        return false
      }
      return values.isDirectory == true && values.isPackage != true
    }.sorted {
      $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }
    return LocalFolderListing(
      directory: directory, folders: Array(folders.prefix(limit)), total: folders.count)
  }
}

import Foundation

/// Stable descriptions and resume keys; file URLs remain the current validated mount URLs.
public enum SMBMediaIdentity {
  public static func displayFilename(_ item: MediaItem) -> String? {
    guard item.source == "local" else { return nil }
    if let raw = item.url, let url = URL(string: raw), url.isFileURL { return url.lastPathComponent }
    guard item.id.hasPrefix("mtv:smb:"), let marker = item.id.range(of: "\nfile:") else { return nil }
    return String(item.id[marker.upperBound...].split(separator: "/").last ?? "")
  }
  public static func namespace(_ profile: SMBProfile) throws -> String {
    try profile.validate()
    return "mtv:smb:" + profile.id.uuidString.lowercased() + "\n" + (try profile.credentialScope)
      + "\n" + (profile.guest ? "guest" : "user:" + profile.username)
  }
  public static func remap(_ files: [MediaItem], profile: SMBProfile, mount: URL) throws
    -> [MediaItem]
  {
    let prefix = try namespace(profile)
    return try files.map { original in
      guard original.source == "local", !original.isFolder, !original.isLibraryCollection,
        let raw = original.url, let url = URL(string: raw)
      else { throw MTVError.message("NAS 索引含无效媒体条目") }
      let path = try relativePath(url, mount: mount)
      guard !path.isEmpty else { throw MTVError.message("NAS 媒体地址不能是挂载根目录") }
      var item = original
      item.id = prefix + "\nfile:" + path
      if var metadata = item.localMetadata, let root = metadata.seriesRoot,
        let title = metadata.seriesTitle, metadata.season != nil, metadata.episode != nil
      {
        let seriesRoot = try relativePath(URL(fileURLWithPath: root, isDirectory: true), mount: mount)
        let name = title.folding(
          options: [.caseInsensitive, .diacriticInsensitive],
          locale: Locale(identifier: "en_US_POSIX"))
        let identity = try JSONEncoder().encode([seriesRoot, name])
        metadata.seriesIdentity = prefix + "\nseries:" + String(decoding: identity, as: UTF8.self)
        item.localMetadata = metadata
      }
      return item
    }
  }
  public static func relativePath(_ url: URL, mount: URL) throws -> String {
    guard url.isFileURL, mount.isFileURL, url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil,
      url.host == nil || url.host == "" || url.host == "localhost"
    else { throw MTVError.message("NAS 媒体地址无效") }
    let root = mount.standardizedFileURL.path
    let path = url.standardizedFileURL.path
    guard root != "/", path == root || path.hasPrefix(root + "/") else {
      throw MTVError.message("NAS 媒体地址超出当前挂载范围")
    }
    return path == root ? "" : String(path.dropFirst(root.count + 1))
  }
  public static func fileURL(relativePath: String, mount: URL) throws -> URL {
    let segments = relativePath.split(separator: "/", omittingEmptySubsequences: false)
    guard !relativePath.hasPrefix("/"), !relativePath.contains("\0"), relativePath.utf8.count <= 4096,
      relativePath.isEmpty || segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
    else { throw MTVError.message("NAS 缓存相对路径无效") }
    let url = relativePath.isEmpty ? mount : mount.appendingPathComponent(relativePath)
    guard try self.relativePath(url, mount: mount) == relativePath else { throw MTVError.message("NAS 缓存路径越界") }
    return url
  }
}

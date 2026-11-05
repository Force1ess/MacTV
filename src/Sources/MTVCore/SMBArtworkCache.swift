import CryptoKit
import Darwin
import Foundation
import ImageIO
import UniformTypeIdentifiers

public struct SMBCachedArtwork: Codable, Equatable {
  public let path: String
  public let revision: String
  public func url(namespace: String, profileID: UUID) throws -> URL {
    _ = try SMBMediaIdentity.fileURL(
      relativePath: path, mount: URL(fileURLWithPath: "/mtv-artwork-validation"))
    guard !path.isEmpty, revision.count <= 80,
      revision.range(of: #"^[0-9]+_-?[0-9]+_[0-9]+$"#, options: .regularExpression) != nil
    else { throw MTVError.message("NAS 封面缓存引用无效") }
    let digest = SHA256.hash(data: Data((namespace + "\n" + path).utf8)).map {
      String(format: "%02x", $0)
    }.joined()
    return URL(
      string: "mtv-artwork://smb/" + profileID.uuidString.lowercased() + "/" + digest + "/"
        + revision)!
  }
  public static func isLocalReference(_ url: URL) -> Bool {
    guard url.scheme == "mtv-artwork", url.host == "smb", url.user == nil, url.password == nil,
      url.query == nil, url.fragment == nil
    else { return false }
    let parts = url.path.split(separator: "/").map(String.init)
    return parts.count == 3 && UUID(uuidString: parts[0]) != nil
      && parts[1].range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil
      && parts[2].count <= 80
      && parts[2].range(of: #"^[0-9]+_-?[0-9]+_[0-9]+$"#, options: .regularExpression) != nil
  }
}

/// Copies only verified, bounded image data into MTV's disposable artwork store.
public actor SMBArtworkCache {
  public let disk: ArtworkDiskStore
  public init(disk: ArtworkDiskStore = ArtworkDiskStore()) { self.disk = disk }
  public func cache(_ url: URL, profile: SMBProfile, mount: URL, verifying share: MountedSMBShare? = nil) async throws -> SMBCachedArtwork {
    try Task.checkCancellation()
    try share?.validateCurrentMount()
    let relative = try SMBMediaIdentity.relativePath(url, mount: mount)
    guard !relative.isEmpty else { throw MTVError.message("封面不能是目录") }
    let root = mount.resolvingSymlinksInPath().standardizedFileURL
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    let actual = try SMBMediaIdentity.relativePath(resolved, mount: root)
    let pair = try Self.readImage(root: root, path: actual)
    try share?.validateCurrentMount()
    try Task.checkCancellation()
    let reference = SMBCachedArtwork(path: relative, revision: pair.1)
    let key = try reference.url(
      namespace: SMBMediaIdentity.namespace(profile), profileID: profile.id)
    try await disk.write(pair.0, for: key)
    try share?.validateCurrentMount()
    return reference
  }
  private static func readImage(root: URL, path: String) throws -> (Data, String) {
    let parts = path.split(separator: "/").map(String.init)
    guard !parts.isEmpty, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
      throw MTVError.message("封面路径无效")
    }
    var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw CocoaError(.fileReadNoPermission) }
    defer { close(directory) }
    for part in parts.dropLast() {
      let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard next >= 0 else { throw CocoaError(.fileReadNoPermission) }
      close(directory)
      directory = next
    }
    let fd = openat(directory, parts.last!, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_size > 0, before.st_size <= 15_000_000
    else { throw CocoaError(.fileReadTooLarge) }
    let bytes = try handle.read(upToCount: 15_000_001) ?? Data()
    var after = stat()
    guard bytes.count == before.st_size, fstat(fd, &after) == 0,
      before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
      let source = CGImageSourceCreateWithData(bytes as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
      let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
      let height = properties[kCGImagePropertyPixelHeight as String] as? Int,
      width > 0, height > 0, width <= 30_000, height <= 30_000,
      Int64(width) * Int64(height) <= 40_000_000,
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceCreateThumbnailWithTransform: true,
          kCGImageSourceThumbnailMaxPixelSize: 1800, kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    else { throw MTVError.message("封面无效、读取中变化或像素尺寸过大") }
    let result = NSMutableData()
    guard
      let target = CGImageDestinationCreateWithData(
        result, UTType.jpeg.identifier as CFString, 1, nil)
    else {
      throw MTVError.message("无法生成封面缩略图")
    }
    CGImageDestinationAddImage(
      target, image, [kCGImageDestinationLossyCompressionQuality: 0.88] as CFDictionary)
    guard CGImageDestinationFinalize(target) else { throw MTVError.message("无法保存封面缩略图") }
    return (
      result as Data,
      "\(before.st_size)_\(before.st_mtimespec.tv_sec)_\(before.st_mtimespec.tv_nsec)"
    )
  }
}

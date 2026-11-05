import Darwin
import Foundation

public enum ScopedFileAccess: Hashable, Sendable {
  case unrestricted
  case within(URL)
  case verifiedSMB(MountedSMBShare)
  case denied
}
public typealias ArtworkFileAccess = ScopedFileAccess

/// Bounded read of a resolved regular file. Scope roots are trusted canonical mount roots.
public enum ScopedFileReader {
  public static func canonicalPath(_ url: URL) throws -> String {
    guard url.isFileURL, let pointer = url.path.withCString({ realpath($0, nil) }) else { throw CocoaError(.fileReadNoPermission) }
    defer { free(pointer) }
    return String(cString: pointer)
  }
  public static func read(_ url: URL, access: ScopedFileAccess, maximumBytes: Int, changedMessage: String = "文件在读取期间发生变化") throws -> Data {
    guard (1...15_000_000).contains(maximumBytes) else { throw CocoaError(.fileReadTooLarge) }
    guard url.isFileURL, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.host == nil || url.host == "" || url.host == "localhost", access != .denied else { throw CocoaError(.fileReadNoPermission) }
    if case .verifiedSMB(let share) = access { try share.validateCurrentMount() }
    let resolved = try canonicalPath(url)
    let scopedRoot: URL?
    switch access { case .within(let root): scopedRoot = root; case .verifiedSMB(let share): scopedRoot = URL(fileURLWithPath: try canonicalPath(share.mount)); default: scopedRoot = nil }
    if let root = scopedRoot {
      let boundary = root.path
      guard resolved.hasPrefix(boundary == "/" ? "/" : boundary + "/") else { throw CocoaError(.fileReadNoPermission) }
    }
    let parts = resolved.split(separator: "/").map(String.init)
    guard let leaf = parts.last, !parts.contains("..") else { throw CocoaError(.fileReadNoPermission) }
    var directory = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw CocoaError(.fileReadNoPermission) }
    defer { close(directory) }
    for part in parts.dropLast() {
      let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard next >= 0 else { throw CocoaError(.fileReadNoPermission) }
      close(directory); directory = next
    }
    let fd = openat(directory, leaf, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard fd >= 0 else { throw CocoaError(.fileReadNoPermission) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    defer { try? handle.close() }
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
      before.st_size > 0, before.st_size <= maximumBytes else { throw CocoaError(.fileReadTooLarge) }
    let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
    var after = stat()
    guard data.count == before.st_size, fstat(fd, &after) == 0, LibraryNodeIdentity(before) == LibraryNodeIdentity(after) else {
      throw MTVError.message(changedMessage)
    }
    if case .verifiedSMB(let share) = access { try share.validateCurrentMount() }
    return data
  }
}
public enum ArtworkFileReader {
  public static func canonicalPath(_ url: URL) throws -> String { try ScopedFileReader.canonicalPath(url) }
  public static func read(_ url: URL, access: ArtworkFileAccess = .unrestricted) throws -> Data {
    try ScopedFileReader.read(url, access: access, maximumBytes: 15_000_000, changedMessage: "图片在读取期间发生变化")
  }
}

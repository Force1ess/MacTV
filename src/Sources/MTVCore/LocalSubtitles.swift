import Foundation

public struct LocalSubtitleCandidate: Hashable, Sendable {
  public let url: URL
  fileprivate let boundary: URL
  public var filename: String { url.lastPathComponent }
}
public struct LocalSubtitleListing: Sendable {
  public let candidates: [LocalSubtitleCandidate]
  public let limited: Bool
}
/// An owned snapshot, retained until the player has released it. Never changes the original subtitle.
public final class PreparedLocalSubtitle: @unchecked Sendable {
  public let source: LocalSubtitleCandidate
  public let url: URL
  private let directory: URL
  fileprivate init(source: LocalSubtitleCandidate, url: URL, directory: URL) { self.source = source; self.url = url; self.directory = directory }
  deinit { try? FileManager.default.removeItem(at: directory) }
}
public enum LocalSubtitles {
  public static let extensions: Set<String> = ["srt", "ass", "ssa", "vtt"]
  public static let maximumBytes = 8_000_000
  private static func root(_ access: ScopedFileAccess) throws -> URL {
    switch access {
    case .within(let root): return URL(fileURLWithPath: try ScopedFileReader.canonicalPath(root))
    case .verifiedSMB(let share): try share.validateCurrentMount(); return URL(fileURLWithPath: try ScopedFileReader.canonicalPath(share.mount))
    default: throw CocoaError(.fileReadNoPermission)
    }
  }
  private static func checked(_ url: URL, root: URL) throws -> URL {
    guard url.isFileURL, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
      url.host == nil || url.host == "" || url.host == "localhost" else { throw CocoaError(.fileReadNoPermission) }
    let path = try ScopedFileReader.canonicalPath(url)
    guard path.hasPrefix(root.path == "/" ? "/" : root.path + "/") else { throw CocoaError(.fileReadNoPermission) }
    return URL(fileURLWithPath: path)
  }
  public static func discover(for media: URL, access: ScopedFileAccess) throws -> LocalSubtitleListing {
    try Task.checkCancellation()
    let boundary = try root(access), file = try checked(media, root: boundary)
    guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { throw CocoaError(.fileReadUnknown) }
    let folder = file.deletingLastPathComponent(), stem = file.deletingPathExtension().lastPathComponent
    var failure: Error?
    guard let entries = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants], errorHandler: { _, error in failure = error; return false }) else { throw CocoaError(.fileReadUnknown) }
    var values: [LocalSubtitleCandidate] = [], seen = Set<URL>(), visited = 0, limited = false
    for case let entry as URL in entries {
      try Task.checkCancellation()
      visited += 1; if visited > 2000 { limited = true; break }
      let name = entry.deletingPathExtension().lastPathComponent
      guard extensions.contains(entry.pathExtension.lowercased()), name == stem || name.hasPrefix(stem + "."),
        entry.lastPathComponent.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else { continue }
      guard let resolved = try? checked(entry, root: boundary), extensions.contains(resolved.pathExtension.lowercased()),
        let attrs = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]), attrs.isRegularFile == true,
        let bytes = attrs.fileSize, bytes > 0, bytes <= maximumBytes, seen.insert(resolved).inserted else { continue }
      values.append(LocalSubtitleCandidate(url: resolved, boundary: boundary))
      if values.count == 64 { limited = true; break }
    }
    if let failure { throw failure }
    if case .verifiedSMB(let share) = access { try share.validateCurrentMount() }
    return LocalSubtitleListing(candidates: values.sorted { $0.filename.localizedStandardCompare($1.filename) == .orderedAscending }, limited: limited)
  }
  public static func prepare(_ candidate: LocalSubtitleCandidate, access: ScopedFileAccess, storage: URL? = nil, converter: WebVTTConverter? = .bundled) throws -> PreparedLocalSubtitle {
    try Task.checkCancellation()
    let boundary = try root(access), resolved = try checked(candidate.url, root: boundary)
    guard boundary == candidate.boundary else { throw CocoaError(.fileReadNoPermission) }
    guard extensions.contains(resolved.pathExtension.lowercased()) else { throw CocoaError(.fileReadUnsupportedScheme) }
    let readAccess: ScopedFileAccess
    if case .within = access { readAccess = .within(boundary) } else { readAccess = access }
    var data = try ScopedFileReader.read(resolved, access: readAccess, maximumBytes: maximumBytes)
    let webvtt = resolved.pathExtension.lowercased() == "vtt"
    if webvtt {
      guard let converter else { throw MTVError.message("此构建未包含 WebVTT 转换组件。") }
      data = try converter.convert(data)
    }
    try Task.checkCancellation()
    let parent = storage ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/PlaybackSubtitles")
    let directory = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    do {
      let name = webvtt ? URL(fileURLWithPath: candidate.filename).deletingPathExtension().lastPathComponent + ".ass" : candidate.filename
      let destination = directory.appendingPathComponent(name)
      try data.write(to: destination, options: .withoutOverwriting)
      return PreparedLocalSubtitle(source: candidate, url: destination, directory: directory)
    } catch { try? FileManager.default.removeItem(at: directory); throw error }
  }
}
/// Filesystem calls stay off the UI actor and cannot overlap across dismissed menus.
public actor LocalSubtitleReader {
  public init() {}
  public func discover(for media: URL, access: ScopedFileAccess) throws -> LocalSubtitleListing { try LocalSubtitles.discover(for: media, access: access) }
  public func prepare(_ candidate: LocalSubtitleCandidate, access: ScopedFileAccess) throws -> PreparedLocalSubtitle { try LocalSubtitles.prepare(candidate, access: access) }
}

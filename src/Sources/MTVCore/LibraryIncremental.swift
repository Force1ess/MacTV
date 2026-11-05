import Darwin
import Foundation

public struct LibraryNodeIdentity: Codable, Equatable, Sendable {
  let device: Int64
  let inode: UInt64
  let mode: UInt32
  let size: Int64
  let modifiedSeconds: Int64
  let modifiedNanos: Int64
  let changedSeconds: Int64
  let changedNanos: Int64
  init(_ value: stat) {
    device = Int64(value.st_dev); inode = UInt64(value.st_ino); mode = UInt32(value.st_mode); size = value.st_size
    modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
    changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
  }
}
public struct LibraryDependencyStamp: Codable, Equatable, Sendable {
  let path: String
  let resolved: String
  let blocked: Bool
  let link: LibraryNodeIdentity?
  let target: LibraryNodeIdentity?
  let error: Int32
}
public struct LibraryIncrementalManifest: Codable, Sendable {
  let schema: Int
  let dependencies: [LibraryDependencyStamp]
  let files: [String: [Int]]
  var metadataParserVersion: Int? = nil
  func validate(itemIDs: Set<String>) throws {
    guard schema == 1, dependencies.count <= 100_000, files.count <= 10_000,
      Set(files.keys).isSubset(of: itemIDs), Set(dependencies.map(\.path)).count == dependencies.count,
      dependencies.allSatisfy({ $0.path.hasPrefix("/") && $0.path.utf8.count <= 8192 && $0.resolved.hasPrefix("/") && $0.resolved.utf8.count <= 8192 }),
      files.values.allSatisfy({ !$0.isEmpty && $0.count <= 128 && Set($0).count == $0.count && $0.allSatisfy { dependencies.indices.contains($0) } })
    else { throw MTVError.message("增量索引格式无效") }
  }
}
public struct LibraryIncrementalState: Sendable {
  public let root: String
  let items: [String: MediaItem]
  public let manifest: LibraryIncrementalManifest
  public init(root: URL, items: [MediaItem], manifest: LibraryIncrementalManifest) {
    self.root = root.standardizedFileURL.path
    self.items = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    self.manifest = manifest
  }
}

/// One shared stamp per dependency; records use integer references, never content hashes.
final class LibraryIncrementalBuilder {
  private static let metadataParserVersion = 7
  private let root: URL
  private let boundary: String?
  private let previous: LibraryIncrementalState?
  private var stamps: [LibraryDependencyStamp] = []
  private var ids: [String: Int] = [:]
  private var files: [String: [Int]] = [:]
  private var tracked = Set<Int>()
  private struct DirectoryInventory {
    let resolved: String
    let identity: LibraryNodeIdentity
    let names: Set<String>
    let originalNames: Set<String>
  }
  private var directories: [String: DirectoryInventory] = [:]
  private var skippedDirectories = Set<String>()
  private var inventoryNames = 0
  init(root: URL, boundary: String?, previous: LibraryIncrementalState?) {
    self.root = root; self.boundary = boundary
    self.previous = previous?.root == root.path && previous?.manifest.metadataParserVersion == Self.metadataParserVersion ? previous : nil
  }
  func directoryNames(_ folder: URL) -> Set<String>? { inventory(folder)?.originalNames }
  private func inventory(_ folder: URL) -> DirectoryInventory? {
    if let value = directories[folder.path] { return value }
    if skippedDirectories.contains(folder.path) { return nil }
    let resolved = folder.resolvingSymlinksInPath().path
    let rootPath = root.resolvingSymlinksInPath().path
    if let boundary, resolved != boundary && !resolved.hasPrefix(boundary + "/") {
      skippedDirectories.insert(folder.path); return nil
    }
    guard resolved == rootPath || resolved.hasPrefix(rootPath + "/"), inventoryNames < 100_000 else {
      skippedDirectories.insert(folder.path); return nil
    }
    var node = stat()
    guard folder.path.withCString({ fstatat(AT_FDCWD, $0, &node, 0) }) == 0,
      let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path),
      names.count <= 100_000 - inventoryNames else { skippedDirectories.insert(folder.path); return nil }
    let value = DirectoryInventory(resolved: resolved, identity: LibraryNodeIdentity(node), names: Set(names.map {
      $0.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }), originalNames: Set(names))
    directories[folder.path] = value; inventoryNames += names.count
    return value
  }
  private func stamp(_ path: String, useInventory: Bool = true) -> LibraryDependencyStamp {
    let url = URL(fileURLWithPath: path), parent = URL(fileURLWithPath: path).deletingLastPathComponent()
    // Only ASCII candidate names use negative directory lookup; other names take the full filesystem path.
    if useInventory, url.lastPathComponent.utf8.allSatisfy({ $0 < 128 }),
      let directory = inventory(parent), !directory.names.contains(url.lastPathComponent.lowercased()) {
      return LibraryDependencyStamp(path: path, resolved: URL(fileURLWithPath: directory.resolved).appendingPathComponent(url.lastPathComponent).path,
        blocked: false, link: nil, target: nil, error: ENOENT)
    }
    let resolved = url.resolvingSymlinksInPath().path
    if let boundary, resolved != boundary && !resolved.hasPrefix(boundary + "/") {
      return LibraryDependencyStamp(path: path, resolved: resolved, blocked: true, link: nil, target: nil, error: 0)
    }
    var link = stat(), target = stat()
    let linkOK = path.withCString { lstat($0, &link) } == 0
    let linkError = linkOK ? 0 : errno
    if linkOK, link.st_mode & S_IFMT != S_IFLNK {
      return LibraryDependencyStamp(path: path, resolved: resolved, blocked: false,
        link: nil, target: LibraryNodeIdentity(link), error: 0)
    }
    let targetOK = linkOK && path.withCString { fstatat(AT_FDCWD, $0, &target, 0) } == 0
    let targetError = targetOK ? 0 : (linkOK ? errno : linkError)
    return LibraryDependencyStamp(path: path, resolved: resolved, blocked: false,
      link: linkOK ? LibraryNodeIdentity(link) : nil, target: targetOK ? LibraryNodeIdentity(target) : nil, error: targetError)
  }
  func observe(_ paths: [String]) -> [Int] {
    Array(Set(paths)).sorted().map { path in
      if let id = ids[path] { return id }
      let id = stamps.count; ids[path] = id; stamps.append(stamp(path)); return id
    }
  }
  func reused(file: URL, dependencies: [Int]) -> MediaItem? {
    guard let previous, let item = previous.items[file.path], item.source == "local", item.metadataAttribution == nil,
      item.localMetadata?.metadataReadFailed != true,
      item.url == file.absoluteString, let old = previous.manifest.files[file.path], old.count == dependencies.count,
      zip(old, dependencies).allSatisfy({ old, new in
        previous.manifest.dependencies.indices.contains(old) && stamps.indices.contains(new)
          && previous.manifest.dependencies[old] == stamps[new] && [0, ENOENT, ENOTDIR].contains(stamps[new].error)
      }) else { return nil }
    return item
  }
  func record(file: URL, dependencies: [Int], readable: Bool) {
    if readable && dependencies.allSatisfy({ stamps[$0].error == 0 || stamps[$0].error == ENOENT || stamps[$0].error == ENOTDIR }) {
      guard tracked.count + dependencies.filter({ !tracked.contains($0) }).count <= 100_000 else { return }
      files[file.path] = dependencies
      tracked.formUnion(dependencies)
    }
  }
  func hasNFOReadErrors(_ dependencies: [Int]) -> Bool {
    dependencies.contains { id in
      let node = stamps[id]
      guard node.path.lowercased().hasSuffix(".nfo"), !node.blocked else { return false }
      return node.error != 0 && (![ENOENT, ENOTDIR].contains(node.error) || node.link != nil)
    }
  }
  func finish(items: [MediaItem]) throws -> LibraryIncrementalState {
    let mediaIDs = Set(items.map(\.id))
    let unchangedDirectories = Set(directories.compactMap { path, before -> String? in
      guard URL(fileURLWithPath: path).resolvingSymlinksInPath().path == before.resolved else { return nil }
      var node = stat()
      guard path.withCString({ fstatat(AT_FDCWD, $0, &node, 0) }) == 0, LibraryNodeIdentity(node) == before.identity else { return nil }
      return path
    })
    for before in stamps {
      try Task.checkCancellation()
      let canUseInventory = unchangedDirectories.contains(URL(fileURLWithPath: before.path).deletingLastPathComponent().path)
      if before != stamp(before.path, useInventory: canUseInventory) {
        // A growing media file must not prevent other films from refreshing.
        // Its description is valid, but no reuse record survives this scan.
        if mediaIDs.contains(before.path) { files.removeValue(forKey: before.path); continue }
        throw MTVError.message("扫描期间影片资料发生变化；保留旧索引，请重新刷新")
      }
    }
    var retainedIDs = Set(files.values.flatMap { $0 })
    for id in stamps.indices where LocalArtworkCandidates.extensions.contains(URL(fileURLWithPath: stamps[id].path).pathExtension.lowercased()) && retainedIDs.count < 100_000 {
      retainedIDs.insert(id)
    }
    let retained = retainedIDs.sorted()
    let offsets = Dictionary(uniqueKeysWithValues: retained.enumerated().map { ($0.element, $0.offset) })
    let compact = files.mapValues { $0.map { offsets[$0]! } }
    let manifest = LibraryIncrementalManifest(schema: 1, dependencies: retained.map { stamps[$0] }, files: compact, metadataParserVersion: Self.metadataParserVersion)
    try manifest.validate(itemIDs: Set(items.map(\.id)))
    return LibraryIncrementalState(root: root, items: items, manifest: manifest)
  }
}

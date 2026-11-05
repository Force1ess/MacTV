import Foundation
import SwiftUI
import MTVCore

@MainActor final class ArtworkRefresh: ObservableObject {
  static let shared = ArtworkRefresh()
  @Published private(set) var generation: UInt64 = 0
  private var epoch: UInt64 = 0
  private var versions: [URL: UInt64] = [:]
  @Published private var shareRoots: [String: URL] = [:]
  @Published private var verifiedShares: [String: MountedSMBShare] = [:]
  private let managedMounts: URL
  private let canonicalManagedMounts: URL
  init() {
    managedMounts = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Mounts").standardizedFileURL
    canonicalManagedMounts = managedMounts.resolvingSymlinksInPath().standardizedFileURL
  }
  func setShareRoots(_ roots: Set<URL>) {
    let pairs = roots.compactMap { root -> (String, URL)? in
      guard let canonical = try? ArtworkFileReader.canonicalPath(root) else { return nil }
      return (root.standardizedFileURL.path, URL(fileURLWithPath: canonical))
    }
    let values = Dictionary(pairs, uniquingKeysWith: { first, _ in first })
    if values != shareRoots { shareRoots = values }
  }
  func setSMBShares(_ shares: [MountedSMBShare]) {
    let valid = shares.filter { (try? $0.validateCurrentMount()) != nil }
    verifiedShares = Dictionary(valid.map { ($0.mount.standardizedFileURL.path, $0) }, uniquingKeysWith: { first, _ in first })
    setShareRoots(Set(valid.map(\.mount)))
  }
  func access(for url: URL) -> ArtworkFileAccess {
    guard url.isFileURL else { return .unrestricted }
    let path = url.standardizedFileURL.path
    if let scope = shareRoots.filter({ path == $0.key || path.hasPrefix($0.key + "/") || path == $0.value.path || path.hasPrefix($0.value.path + "/") })
      .max(by: { $0.key.count < $1.key.count }) {
      if let share = verifiedShares[scope.key] { return .verifiedSMB(share) }
      return .within(scope.value)
    }
    if [managedMounts.path, canonicalManagedMounts.path].contains(where: { path == $0 || path.hasPrefix($0 + "/") }) { return .denied }
    return .unrestricted
  }
  func version(for url: URL) -> UInt64 {
    guard url.isFileURL else { return 0 }
    return versions[url.standardizedFileURL] ?? epoch
  }
  func invalidate(_ urls: Set<URL>) {
    let files = Set(urls.filter(\.isFileURL).map(\.standardizedFileURL))
    guard !files.isEmpty else { return }
    let next = generation &+ 1
    if versions.count + files.filter({ versions[$0] == nil }).count > 10_000 {
      versions.removeAll(); epoch = next
    }
    if files.count <= 10_000 { for file in files { versions[file] = next } }
    generation = next
  }
}

struct ArtworkRequestKey: Hashable, Sendable {
  let url: URL
  let revision: UInt64
  let access: ArtworkFileAccess
  var cacheKey: NSString { "\(revision)\n\(access)\n\(url.absoluteString)" as NSString }
}

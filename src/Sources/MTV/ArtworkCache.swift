import AppKit
import Foundation
import ImageIO
import MTVCore
import OSLog

private actor ArtworkJobs {
  private var tasks: [ArtworkRequestKey: Task<NSImage?, Never>] = [:]
  func image(_ key: ArtworkRequestKey, operation: @escaping @Sendable () async -> NSImage?) async -> NSImage? {
    if let task = tasks[key] { return await task.value }
    let task = Task { await operation() }
    tasks[key] = task
    let value = await task.value
    tasks[key] = nil
    return value
  }
}

private actor ArtworkStatistics {
  private var count = 0
  private var local: [URL: Int] = [:]
  func requested() { count += 1 }
  func requests() -> Int { count }
  func fileRead(_ url: URL) { local[url, default: 0] += 1 }
  func fileReads(_ url: URL) -> Int { local[url] ?? 0 }
}

/// Decodes off the UI thread. Local artwork is never copied or rewritten.
final class ArtworkCache: @unchecked Sendable {
  static let shared: ArtworkCache = {
    guard CommandLine.arguments.contains("--ui-smoke") else { return ArtworkCache() }
    let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/MTV/TestResults")
    if let index = CommandLine.arguments.firstIndex(of: "--smb-offline-test-scope"),
      index + 1 < CommandLine.arguments.count,
      let scope = UUID(uuidString: CommandLine.arguments[index + 1])
    {
      return ArtworkCache(
        disk: ArtworkDiskStore(
          root: base.appendingPathComponent(
            "SMBOfflineStartup-" + scope.uuidString.lowercased() + "/artwork")))
    }
    return ArtworkCache(
      disk: ArtworkDiskStore(
        root: base.appendingPathComponent(
          "ArtworkSession-\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)")))
  }()
  private let cache = NSCache<NSString, NSImage>()
  private let session: URLSession
  let disk: ArtworkDiskStore
  private let allowsNetwork: Bool
  private let jobs = ArtworkJobs()
  private let statistics = ArtworkStatistics()
  func networkRequests() async -> Int { await statistics.requests() }
  func localReads(for url: URL) async -> Int { await statistics.fileReads(url) }
  private let log = Logger(subsystem: "local.mtv.preview", category: "artwork-cache")
  init(disk: ArtworkDiskStore = ArtworkDiskStore(), allowsNetwork: Bool = true) {
    self.disk = disk
    self.allowsNetwork = allowsNetwork
    cache.totalCostLimit = 96 * 1024 * 1024
    cache.countLimit = 160
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.timeoutIntervalForRequest = 10
    configuration.timeoutIntervalForResource = 15
    session = URLSession(configuration: configuration)
  }
  func image(for url: URL, revision: UInt64 = 0, access requestedAccess: ArtworkFileAccess? = nil) async -> NSImage? {
    let access: ArtworkFileAccess
    if url.isFileURL {
      if let requestedAccess { access = requestedAccess }
      else { access = await MainActor.run { ArtworkRefresh.shared.access(for: url) } }
    } else { access = .unrestricted }
    guard access != .denied else { return nil }
    if case .verifiedSMB(let share) = access, (try? share.validateCurrentMount()) == nil { return nil }
    let key = ArtworkRequestKey(url: url, revision: url.isFileURL ? revision : 0, access: access)
    if let image = cache.object(forKey: key.cacheKey) { return image }
    return await jobs.image(key) { [self] in await load(key) }
  }
  private func remember(_ image: NSImage, for key: ArtworkRequestKey) {
    let size = image.size
    cache.setObject(image, forKey: key.cacheKey, cost: Int(size.width * size.height * 4))
  }
  private func load(_ key: ArtworkRequestKey) async -> NSImage? {
    let url = key.url
    if url.scheme == "mactv-music-artwork" {
      guard let data = try? await MusicArtwork.shared.data(url), let image = await Self.decode(data) else { return nil }
      return image
    }
    if url.scheme == "mactv-cloud-photo" {
      guard allowsNetwork, let data = try? await CloudPhotos.shared.thumbnail(url), let image = await Self.decode(data) else { return nil }
      await CloudPhotos.shared.noteDecodedPreview()
      // Never place account-bound cloud photos in the general public artwork cache.
      return image
    }
    if url.isFileURL {
      guard
        let data = try? await Task.detached(
          priority: .utility,
          operation: {
            try ArtworkFileReader.read(url, access: key.access)
          }
        ).value
      else { return nil }
      if CommandLine.arguments.contains("--ui-smoke") { await statistics.fileRead(url) }
      guard let image = await Self.decode(data) else { return nil }
      if case .verifiedSMB(let share) = key.access, (try? share.validateCurrentMount()) == nil { return nil }
      remember(image, for: key)
      return image
    }
    let localReference = SMBCachedArtwork.isLocalReference(url)
    guard localReference || (url.scheme == "https" && url.user == nil && url.password == nil) else {
      return nil
    }
    do {
      if let data = try await disk.read(url) {
        if let image = await Self.decode(data) {
          remember(image, for: key)
          return image
        }
        try await disk.remove(url)
      }
    } catch { log.error("Artwork disk read failed; cache entry was not used") }
    guard allowsNetwork && !localReference else { return nil }
    await statistics.requested()
    guard let response = try? await session.data(from: url),
      (response.1 as? HTTPURLResponse)?.statusCode == 200, response.0.count <= 15_000_000,
      let image = await Self.decode(response.0)
    else { return nil }
    remember(image, for: key)
    do { try await disk.write(response.0, for: url) } catch {
      log.error("Artwork rendered, but disk cache write failed")
    }
    return image
  }
  private static func decode(_ data: Data) async -> NSImage? {
    await Task.detached(priority: .utility) {
      guard let source = CGImageSourceCreateWithData(data as CFData, nil),
        let image = CGImageSourceCreateThumbnailAtIndex(
          source, 0,
          [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: 1800,
          ] as CFDictionary)
      else { return nil }
      return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    }.value
  }
}

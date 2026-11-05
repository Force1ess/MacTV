import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import MTVCore

struct SMBArtworkTests {
  func png() throws -> Data {
    let context = CGContext(
      data: nil, width: 12, height: 18, bitsPerComponent: 8, bytesPerRow: 48,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 12, height: 18))
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(
      data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
  }
  @Test func verifiedImageSurvivesNewCacheWithoutSourceAndDoesNotModifyOriginal() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let mount = root.appendingPathComponent("mount")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    let image = mount.appendingPathComponent("poster.jpg")
    let original = try png()
    try original.write(to: image)
    let profile = try SMBProfile(
      address: "nas/Movies", username: "", guest: true, rememberPassword: false)
    let diskRoot = root.appendingPathComponent("cache")
    let importer = SMBArtworkCache(disk: ArtworkDiskStore(root: diskRoot))
    let reference = try await importer.cache(image, profile: profile, mount: mount)
    #expect(try Data(contentsOf: image) == original)
    let key = try reference.url(
      namespace: SMBMediaIdentity.namespace(profile), profileID: profile.id)
    #expect(SMBCachedArtwork.isLocalReference(key))
    try FileManager.default.removeItem(at: mount)
    let cached = try #require(try await ArtworkDiskStore(root: diskRoot).read(key))
    #expect(CGImageSourceCreateWithData(cached as CFData, nil) != nil)
  }
  @Test func escapesCorruptionAndDirectoriesNeverBecomeCachedImages() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let mount = root.appendingPathComponent("mount")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    let outside = root.appendingPathComponent("outside.png")
    try png().write(to: outside)
    let link = mount.appendingPathComponent("escape.jpg")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    let invalid = mount.appendingPathComponent("invalid.jpg")
    try Data("not an image".utf8).write(to: invalid)
    let profile = try SMBProfile(
      address: "nas/Movies", username: "", guest: true, rememberPassword: false)
    let importer = SMBArtworkCache(
      disk: ArtworkDiskStore(root: root.appendingPathComponent("cache")))
    for input in [outside, link, invalid, mount] {
      await #expect(throws: (any Error).self) {
        try await importer.cache(input, profile: profile, mount: mount)
      }
    }
  }
  @Test func portableIndexRestoresPosterAndSeriesCoverReferences() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let mount = root.appendingPathComponent("mount")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    let image = mount.appendingPathComponent("poster.jpg")
    try png().write(to: image)
    let video = mount.appendingPathComponent("Example.Show.S01E01.mp4")
    try Data().write(to: video)
    let profile = try SMBProfile(
      address: "nas/Movies", username: "", guest: true, rememberPassword: false)
    let raw = try LibraryScanner.scanResult(root: mount).withSMBIdentity(
      profile: profile, mount: mount
    ).items
    let importer = SMBArtworkCache(
      disk: ArtworkDiskStore(root: root.appendingPathComponent("cache")))
    let store = SMBLibraryIndexStore(
      root: root.appendingPathComponent("indexes"), artwork: importer)
    let outcome = try await store.saveDetailed(raw, profile: profile, mount: mount)
    #expect(outcome.written && outcome.artworkSkipped == 0)
    try FileManager.default.removeItem(at: mount)
    let snapshot = try #require(try await store.load(profile: profile))
    let offline = snapshot.offlineItems()
    #expect(offline[0].url == nil)
    #expect(offline[0].poster?.hasPrefix("mtv-artwork://") == true)
    #expect(LibraryCatalog.build(offline).root[0].poster?.hasPrefix("mtv-artwork://") == true)
  }
  @Test func artworkFailureDoesNotDropCatalogAndVirtualMissIsDistinctFromHTTP() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let mount = root.appendingPathComponent("mount")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    try Data().write(to: mount.appendingPathComponent("Movie.2024.mp4"))
    try Data("broken".utf8).write(to: mount.appendingPathComponent("poster.jpg"))
    let profile = try SMBProfile(
      address: "nas/Movies", username: "", guest: true, rememberPassword: false)
    let items = try LibraryScanner.scanResult(root: mount).withSMBIdentity(
      profile: profile, mount: mount
    ).items
    let store = SMBLibraryIndexStore(
      root: root.appendingPathComponent("indexes"),
      artwork: SMBArtworkCache(disk: ArtworkDiskStore(root: root.appendingPathComponent("cache"))))
    let result = try await store.saveDetailed(items, profile: profile, mount: mount)
    #expect(result.written && result.artworkSkipped == 1)
    #expect(try await store.load(profile: profile)?.records.count == 1)
    #expect(!SMBCachedArtwork.isLocalReference(URL(string: "mtv-artwork://other/private")!))
  }
  @Test func cancelledArtworkSaveDoesNotReplaceExistingCatalog() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let mount = root.appendingPathComponent("mount")
    try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
    try Data().write(to: mount.appendingPathComponent("Movie.2024.mp4"))
    let profile = try SMBProfile(
      address: "nas/Movies", username: "", guest: true, rememberPassword: false)
    let files = try LibraryScanner.scanResult(root: mount).withSMBIdentity(
      profile: profile, mount: mount
    ).items
    let store = SMBLibraryIndexStore(
      root: root.appendingPathComponent("indexes"),
      artwork: SMBArtworkCache(disk: ArtworkDiskStore(root: root.appendingPathComponent("cache"))))
    try await store.save(files, profile: profile, mount: mount)
    let gate = AsyncStream<Void>.makeStream()
    let operation = Task {
      for await _ in gate.stream { break }
      return try await store.saveDetailed([], profile: profile, mount: mount)
    }
    operation.cancel()
    gate.continuation.finish()
    await #expect(throws: CancellationError.self) { try await operation.value }
    #expect(try await store.load(profile: profile)?.records.count == 1)
  }
}

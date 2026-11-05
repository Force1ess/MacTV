import Foundation
import Testing

@testable import MTVCore

struct SMBLibraryIndexTests {
  func files(mount: URL, profile: SMBProfile) throws -> [MediaItem] {
    let movie = mount.appendingPathComponent("Movies/Test.2024.mp4")
    let episode = mount.appendingPathComponent("TV/Example Show/Season 1/Show.S01E01.mp4")
    return try SMBMediaIdentity.remap(
      [
        MediaItem(
          id: movie.path, title: "Movie",
          poster: mount.appendingPathComponent("Movies/poster.jpg").absoluteString,
          url: movie.absoluteString,
          localMetadata: LocalMediaMetadata(year: 2024, hasSidecar: false, sourceReachable: true)),
        MediaItem(
          id: episode.path, title: "Episode", url: episode.absoluteString,
          localMetadata: LocalMediaMetadata(
            seriesTitle: "Example Show",
            seriesRoot: mount.appendingPathComponent("TV/Example Show").path,
            season: 1, episode: 1,
            seriesPoster: mount.appendingPathComponent("TV/Example Show/poster.jpg").absoluteString,
            hasSidecar: false, sourceReachable: true)),
      ], profile: profile, mount: mount)
  }
  @Test func coldOfflineDescriptionsContainNoTransientMountAndRebindCurrentURLs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let profile = try SMBProfile(
      address: "nas/Movies/TV", username: "u", guest: false, rememberPassword: true)
    let a = URL(fileURLWithPath: "/tmp/old-mtv-mount")
    let b = URL(fileURLWithPath: "/tmp/new-mtv-mount")
    let first = try files(mount: a, profile: profile)
    let store = SMBLibraryIndexStore(root: root)
    #expect(try await store.save(first, profile: profile, mount: a))
    let data = try Data(
      contentsOf: root.appendingPathComponent(profile.id.uuidString.lowercased() + ".json"))
    #expect(!String(decoding: data, as: UTF8.self).contains(a.path))
    let loaded = try #require(try await SMBLibraryIndexStore(root: root).load(profile: profile))
    let offline = loaded.offlineItems()
    #expect(
      offline.count == 2
        && offline.allSatisfy {
          $0.url == nil && $0.poster == nil && $0.localMetadata?.sourceReachable == false
        })
    #expect(LibraryCatalog.build(offline).root.contains { $0.kind == .series })
    let bound = try loaded.binding(profile: profile, mount: b)
    #expect(bound.map(\.id) == first.map(\.id))
    #expect(bound.allSatisfy { $0.url?.contains("new-mtv-mount") == true && $0.poster == nil })
  }
  @Test func changedTargetAccountOrSelectedDirectoryCannotLoadOldCache() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let mount = URL(fileURLWithPath: "/tmp/mtv-mount")
    let profile = try SMBProfile(
      address: "nas/Movies/TV", username: "u", guest: false, rememberPassword: false)
    let store = SMBLibraryIndexStore(root: root)
    try await store.save(files(mount: mount, profile: profile), profile: profile, mount: mount)
    for address in ["other/Movies/TV", "nas/Movies/AnotherFolder"] {
      var changed = profile
      changed.address = try SMBProfile.canonicalAddress(address)
      #expect(try await store.load(profile: changed) == nil)
    }
    var user = profile
    user.username = "someone-else"
    #expect(try await store.load(profile: user) == nil)
  }
  @Test func traversalAndCorruptCacheFailWithoutEmptyOverwrite() async throws {
    let mount = URL(fileURLWithPath: "/tmp/mtv-mount")
    for path in ["../outside", "/absolute", "a//b", "a/../b", "nul\0name"] {
      #expect(throws: (any Error).self) {
        try SMBMediaIdentity.fileURL(relativePath: path, mount: mount)
      }
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let profile = try SMBProfile(
      address: "nas/Movies", username: "", guest: true, rememberPassword: false)
    let file = root.appendingPathComponent(profile.id.uuidString.lowercased() + ".json")
    let broken = Data("{broken".utf8)
    try broken.write(to: file)
    let store = SMBLibraryIndexStore(root: root)
    await #expect(throws: (any Error).self) { try await store.load(profile: profile) }
    #expect(try Data(contentsOf: file) == broken)
  }
  @Test func sourceSelectionRemembersNASWithoutSavingMountPath() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let source = LibrarySourceSelection(smbProfileID: id)
    let store = LibrarySourceStore(file: root.appendingPathComponent("source.json"))
    try await store.save(source)
    let cold = try await LibrarySourceStore(file: root.appendingPathComponent("source.json")).load()
    #expect(cold?.smbProfileID == id && cold?.path == nil && cold?.origin == .chosen)
  }
}

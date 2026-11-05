import Foundation
import Testing
@testable import MTVCore

struct LibraryOverviewTests {
  @Test func readsTwoArchivedRootsAndOfflineNASWithoutMediaRootsOrCredentials() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sources = SavedLibrarySourcesStore(file: folder.appendingPathComponent("sources.json"))
    let local = LibraryIndexStore(file: folder.appendingPathComponent("index.json"))
    let nas = SMBLibraryIndexStore(root: folder.appendingPathComponent("nas"))
    let profiles = SMBProfileStore(file: folder.appendingPathComponent("profiles.json"))
    let a = folder.appendingPathComponent("unmounted-A"), b = folder.appendingPathComponent("unmounted-B")
    func movie(_ root: URL) -> MediaItem {
      let file = root.appendingPathComponent("Film.mp4")
      return MediaItem(id: file.path, title: "同名电影", url: file.absoluteString)
    }
    try await local.save(items: [movie(a)], root: a)
    try await local.save(items: [movie(b)], root: b)
    try await sources.remember(LibrarySourceSelection(path: a.path), title: "硬盘 A")
    try await sources.remember(LibrarySourceSelection(path: b.path), title: "硬盘 B")
    let profile = try SMBProfile(address: "unreachable.invalid/Films", username: "", guest: true, rememberPassword: false)
    try await profiles.upsert(profile)
    try await sources.remember(LibrarySourceSelection(smbProfileID: profile.id), title: "NAS")
    let mount = folder.appendingPathComponent("no-mount")
    let items = try SMBMediaIdentity.remap([movie(mount)], profile: profile, mount: mount)
    try await nas.save(items, profile: profile, mount: mount)
    try await sources.remember(LibrarySourceSelection(smbProfileID: UUID()), title: "已移除的 NAS")
    let store = LibraryOverviewStore(sources: sources, local: local, nas: nas, profiles: profiles)
    let rows = try await store.load()
    #expect(rows.count == 4)
    #expect(rows[0].cards[0].title == rows[1].cards[0].title)
    #expect(rows[0].cards[0].id != rows[1].cards[0].id)
    #expect(rows[2].cards[0].offline && rows[2].cards[0].id == items[0].id)
    #expect(rows[3].cards.isEmpty && rows[3].message.contains("连接已移除"))
    #expect(!FileManager.default.fileExists(atPath: a.path))
    #expect(!FileManager.default.fileExists(atPath: b.path))
    #expect(!FileManager.default.fileExists(atPath: mount.path))
    try await profiles.remove(profile.id)
    let changed = try await store.load()
    #expect(changed[2].cards.isEmpty && changed[0].cards.count == 1)
  }
  @Test func boundsCombinedPreviewWithoutHidingSourceAccess() async throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let sources = SavedLibrarySourcesStore(file: folder.appendingPathComponent("sources.json"))
    let local = LibraryIndexStore(file: folder.appendingPathComponent("index.json"))
    for source in 0..<2 {
      let root = folder.appendingPathComponent("unmounted-\(source)")
      let items = (0..<6_000).map { number in
        let file = root.appendingPathComponent("Movie-\(number).mp4")
        return MediaItem(id: file.path, title: "电影 \(number)", url: file.absoluteString)
      }
      try await local.save(items: items, root: root)
      try await sources.remember(LibrarySourceSelection(path: root.path), title: "硬盘 \(source)")
    }
    let store = LibraryOverviewStore(sources: sources, local: local,
      nas: SMBLibraryIndexStore(root: folder.appendingPathComponent("nas")),
      profiles: SMBProfileStore(file: folder.appendingPathComponent("profiles.json")))
    let rows = try await store.load()
    #expect(rows.count == 2 && rows.map(\.fileCount) == [6_000, 6_000])
    #expect(rows.map { $0.cards.count } == [6_000, 4_000])
    #expect(rows[1].message.contains("上限"))
    let searched = try await store.load(query: "电影 5999")
    #expect(searched.count == 2 && searched.allSatisfy { $0.cards.count == 1 && $0.matchingCount == 1 })
    let empty = try await store.load(query: "never-present-title")
    #expect(empty.isEmpty)
  }
  @Test func searchCombinesKeywordsAndRecognizesEpisodeAndUnicode() {
    let item = MediaItem(id: "episode", title: "Café 夜航", subtitle: "完整版", overview: "远方的旅行",
      localMetadata: LocalMediaMetadata(year: 2024, seriesTitle: "太空旅行", season: 2, episode: 3))
    #expect(LibrarySearch("cafe 夜航").matches(item, sourceTitle: "硬盘 B"))
    #expect(LibrarySearch("S02E03 2024").matches(item, sourceTitle: "硬盘 B"))
    #expect(LibrarySearch("太空 硬盘").matches(item, sourceTitle: "硬盘 B"))
    #expect(!LibrarySearch("夜航 2025").matches(item, sourceTitle: "硬盘 B"))
    #expect(LibrarySearch("ＣＡＦＥ").matches(item, sourceTitle: "硬盘 B"))
  }
}

import Foundation
import Testing
@testable import MTVCore

struct WatchlistTests {
  private func context(_ id: String, source: String = "local") throws -> PlaybackHistoryContext {
    try PlaybackHistoryContext(mediaID: id, sourceID: source, title: "待看 " + id, sourceTitle: "来源",
      reference: source == "local" ? nil : "opaque-" + id, librarySource: source == "local" ? LibrarySourceSelection(path: "/tmp/library") : nil)
  }
  @Test func watchlistNeedsNoProgressAndRetainsSourceIdentityAcrossColdStores() throws {
    let scope = UUID(), store = PlaybackResumeStore.isolated(scope: scope)
    defer { store.removeTestDomain() }
    let local = try context("same"), plugin = try context("same", source: "example.video")
    try store.addToWatchlist(local); try store.addToWatchlist(plugin)
    let cold = PlaybackResumeStore.isolated(scope: scope)
    #expect(try cold.watchlist().map(\.sourceID) == ["example.video", "local"])
    #expect(cold.position(for: local.mediaID) == 0 && cold.position(for: plugin.mediaID, source: plugin.sourceID) == 0)
    #expect(try cold.recent().isEmpty)
    try cold.addToWatchlist(local)
    #expect(try cold.watchlist().count == 2)
    #expect(try cold.watchlist().first?.sourceID == "example.video")
  }
  @Test func removingFavoritesPreservesProgressAndHistoryAndHistoryResetPreservesFavorites() throws {
    let store = PlaybackResumeStore.isolated(); defer { store.removeTestDomain() }
    let item = try context("one"), other = try context("two")
    store.save(12, for: item.mediaID, duration: 120); try store.remember(item)
    try store.addToWatchlist(item); try store.addToWatchlist(other); try store.removeFromWatchlist(item.id)
    #expect(store.position(for: item.mediaID) == 12)
    #expect(try store.recent().map(\.id) == [item.id])
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let review = try store.reviewHistoryReset(), backup = try review.writeBackup(in: root)
    try store.commitHistoryReset(backup)
    #expect(try store.watchlist().map(\.id) == [other.id])
    #expect(store.position(for: item.mediaID) == 12)
  }
  @Test func fullWatchlistRejectsNewItemWithoutEvictingAndAllowsMetadataUpdate() throws {
    let store = PlaybackResumeStore.isolated(); defer { store.removeTestDomain() }
    for index in 0..<50 { try store.addToWatchlist(context(String(index))) }
    let before = try store.watchlist()
    #expect(throws: (any Error).self) { try store.addToWatchlist(context("overflow")) }
    #expect(try store.watchlist() == before)
    let updated = try PlaybackHistoryContext(mediaID: "10", sourceID: "local", title: "新名称", sourceTitle: "来源", librarySource: LibrarySourceSelection(path: "/tmp/library"))
    try store.addToWatchlist(updated)
    #expect(try store.watchlist().count == 50)
    #expect(try store.watchlist().first(where: { $0.mediaID == "10" })?.title == "新名称")
    #expect(try store.watchlist().first?.mediaID == before.first?.mediaID)
  }
  @Test func invalidWrongTypedDuplicateAndOversizedWatchlistsAreNeverOverwritten() throws {
    let scope = UUID(), store = PlaybackResumeStore.isolated(scope: scope)
    defer { store.removeTestDomain() }
    let defaults = UserDefaults(suiteName: "local.mtv.preview.resume-fixture." + scope.uuidString.lowercased())!
    let item = try context("one")
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(item))
    let duplicates = try JSONSerialization.data(withJSONObject: ["schema": 1, "contexts": [encoded, encoded]])
    for bad in [Data("not json".utf8), Data(#"{"schema":2,"contexts":[]}"#.utf8), duplicates, Data(repeating: 120, count: 262_145)] {
      defaults.set(bad, forKey: "watchlist.v1")
      #expect(throws: (any Error).self) { try store.addToWatchlist(item) }
      #expect(throws: (any Error).self) { try store.removeFromWatchlist(item.id) }
      #expect(defaults.data(forKey: "watchlist.v1") == bad)
    }
    defaults.set("wrong type", forKey: "watchlist.v1")
    #expect(throws: (any Error).self) { try store.addToWatchlist(item) }
    #expect(defaults.string(forKey: "watchlist.v1") == "wrong type")
  }
  @Test func savedCollectionReferencesRemainStableAndOldHistoryStillDecodes() throws {
    let part = try PlaybackHistoryContext(mediaID: "part", sourceID: "example.video", title: "Part", sourceTitle: "Example",
      reference: "video:part2", collectionReference: "video")
    #expect(try part.replacingPoster("https://images.example.test/cover.jpg").collectionReference == "video")
    for bad in ["https://media.example.test/signed?token=private", "file:///tmp/secret", "bad\nvalue", "", String(repeating: "x", count: 513)] {
      #expect(throws: (any Error).self) {
        try PlaybackHistoryContext(mediaID: "part", sourceID: "example.video", title: "Part", sourceTitle: "Example", reference: "stable", collectionReference: bad)
      }
    }
    #expect(throws: (any Error).self) {
      try PlaybackHistoryContext(mediaID: "https://media.example.test/signed?token=private", sourceID: "example.video", title: "Part", sourceTitle: "Example", reference: "stable")
    }
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(part)) as? [String: Any])
    object.removeValue(forKey: "collectionReference")
    let old = try JSONDecoder().decode(PlaybackHistoryContext.self, from: JSONSerialization.data(withJSONObject: object))
    try old.validate(); #expect(old.collectionReference == nil && old.reference == "video:part2")
  }
}

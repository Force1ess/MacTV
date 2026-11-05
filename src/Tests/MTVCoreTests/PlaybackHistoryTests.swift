import Foundation
import Testing
@testable import MTVCore

struct PlaybackHistoryTests {
  private func local(_ id: String, path: String = "/tmp/mtv-history") throws -> PlaybackHistoryContext {
    try PlaybackHistoryContext(mediaID: id, sourceID: "local", title: "Movie " + id, sourceTitle: "Library", librarySource: LibrarySourceSelection(path: path))
  }
  @Test func recentUsesActualProgressAndPersistsRoutesAcrossStores() throws {
    let scope = UUID()
    let coldStore = PlaybackResumeStore.isolated(scope: scope)
    defer { coldStore.removeTestDomain() }
    let a = try local("first"), b = try PlaybackHistoryContext(mediaID: "first", sourceID: "test.video", title: "Remote", sourceTitle: "Plugin", reference: "opaque-part")
    coldStore.save(12, for: a.mediaID, duration: 120); try coldStore.remember(a)
    coldStore.save(42, for: b.mediaID, source: b.sourceID, duration: 200); try coldStore.remember(b)
    let reopened = PlaybackResumeStore.isolated(scope: scope)
    let entries = try reopened.recent()
    #expect(entries.count == 2)
    #expect(entries.first?.context.sourceID == "test.video")
    #expect(entries.first?.progress.position == 42)
    #expect(entries.last?.context.librarySource?.path == "/tmp/mtv-history")
    try reopened.forgetHistory(b.id)
    #expect(try reopened.recent().count == 1)
    #expect(reopened.position(for: b.mediaID, source: b.sourceID) == 42)
  }
  @Test func resetsAndCompletionDisappearEvenBeforeMetadataRewrite() throws {
    let store = PlaybackResumeStore.isolated(); defer { store.removeTestDomain() }
    let context = try local("one")
    store.save(12, for: context.mediaID, duration: 100); try store.remember(context)
    store.save(1, for: context.mediaID, duration: 100)
    #expect(try store.recent().isEmpty)
    store.save(30, for: context.mediaID, duration: 100); try store.remember(context)
    #expect(try store.recent().count == 1)
    store.save(90, for: context.mediaID, duration: 100)
    #expect(try store.recent().isEmpty)
    try store.remember(context)
    #expect(try store.recent().isEmpty)
  }
  @Test func capacityAndSameMediaAcrossOverlappingRootsAreBounded() throws {
    let store = PlaybackResumeStore.isolated(); defer { store.removeTestDomain() }
    for index in 0..<24 {
      let context = try local("id" + String(index))
      store.save(12, for: context.mediaID, duration: 100); try store.remember(context)
    }
    #expect(try store.recent().count == 20)
    #expect(try !store.recent().contains { $0.context.mediaID == "id0" })
    let replacement = try local("id23", path: "/tmp")
    try store.remember(replacement)
    #expect(try store.recent().filter { $0.context.mediaID == "id23" }.count == 1)
    #expect(try store.recent().first { $0.context.mediaID == "id23" }?.context.librarySource?.path == "/tmp")
  }
  @Test func referencesAndArtworkCannotPersistCredentialsOrTemporaryNASPaths() throws {
    for reference in ["https://media.example/test?token=secret", "file:///private/file", "bad\nreference"] {
      #expect(throws: (any Error).self) { try PlaybackHistoryContext(mediaID: "video", sourceID: "test.plugin", title: "Video", sourceTitle: "Plugin", reference: reference) }
    }
    let profile = LibrarySourceSelection(smbProfileID: UUID())
    #expect(throws: (any Error).self) { try PlaybackHistoryContext(mediaID: "stable-nas", sourceID: "local", title: "NAS", sourceTitle: "NAS", poster: "file:///tmp/mount/poster.jpg", librarySource: profile) }
    let cached = "mtv-artwork://smb/" + profile.smbProfileID!.uuidString.lowercased() + "/" + String(repeating: "a", count: 64) + "/10_0_1"
    _ = try PlaybackHistoryContext(mediaID: "stable-nas", sourceID: "local", title: "NAS", sourceTitle: "NAS", poster: cached, librarySource: profile)
    #expect(throws: (any Error).self) { try PlaybackHistoryContext(mediaID: "video", sourceID: "test.plugin", title: "Video", sourceTitle: "Plugin", poster: "https://example.test/poster?token=secret", reference: "id") }
  }
  @Test func corruptMetadataIsNotOverwrittenAndProgressStaysReadable() throws {
    let scope = UUID()
    let target = PlaybackResumeStore.isolated(scope: scope)
    defer { target.removeTestDomain() }
    let defaults = UserDefaults(suiteName: "local.mtv.preview.resume-fixture." + scope.uuidString.lowercased())!
    let corrupt = Data("broken history".utf8); defaults.set(corrupt, forKey: "watch-history.v1")
    target.save(12, for: "one", duration: 100)
    #expect(throws: (any Error).self) { try target.recent() }
    #expect(throws: (any Error).self) { try target.remember(local("one")) }
    #expect(defaults.data(forKey: "watch-history.v1") == corrupt)
    #expect(target.position(for: "one") == 12)
  }
  @Test func historyCapabilityRequiresResolve() throws {
    var manifest = try JSONDecoder().decode(PluginManifest.self, from: Data(#"{"id":"test.history","name":"History","version":"1","apiVersion":1,"entry":"plugin.js","domains":[],"capabilities":["browse","history"]}"#.utf8))
    #expect(throws: (any Error).self) { try manifest.validate() }
    manifest.capabilities.append("resolve"); try manifest.validate()
  }
}

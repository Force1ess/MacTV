import Foundation
import Testing

@testable import MTVCore

struct SMBMediaIdentityTests {
  func item(in root: URL, path: String = "TV/Example Show/Season 1/Example.Show.S01E01.mp4")
    -> MediaItem
  {
    let file = root.appendingPathComponent(path)
    return MediaItem(
      id: file.path, title: "Episode", url: file.absoluteString,
      localMetadata: LocalMediaMetadata(
        seriesTitle: "Example Show",
        seriesRoot: root.appendingPathComponent("TV/Example Show").path, season: 1, episode: 1))
  }
  @Test func mountChangesKeepMediaSeriesAndSeasonIdentities() throws {
    let a = URL(fileURLWithPath: "/tmp/mtv-mount-a")
    let b = URL(fileURLWithPath: "/tmp/mtv-mount-b")
    let profile = try SMBProfile(
      address: "nas/Movies/TV", username: "viewer", guest: false, rememberPassword: false)
    let first = try SMBMediaIdentity.remap([item(in: a)], profile: profile, mount: a)
    let second = try SMBMediaIdentity.remap([item(in: b)], profile: profile, mount: b)
    #expect(first[0].id == second[0].id && first[0].url != second[0].url)
    #expect(!first[0].id.contains(a.path))
    let left = LibraryCatalog.build(first)
    let right = LibraryCatalog.build(second)
    #expect(left.root[0].id == right.root[0].id)
    #expect(left.children[left.root[0].id]?[0].id == right.children[right.root[0].id]?[0].id)
    var subdirectory = profile
    subdirectory.address = try SMBProfile.canonicalAddress("nas/Movies/AnotherSelection")
    #expect(
      try SMBMediaIdentity.remap([item(in: a)], profile: subdirectory, mount: a)[0].id
        == first[0].id)
  }
  @Test func passwordPreferenceDoesNotChangeMediaIdentity() throws {
    let root = URL(fileURLWithPath: "/tmp/mtv-mount")
    let profile = try SMBProfile(address: "nas/Movies", username: "viewer", guest: false, rememberPassword: false)
    var changed = profile; changed.rememberPassword = true
    #expect(try SMBMediaIdentity.remap([item(in: root)], profile: profile, mount: root)[0].id
      == SMBMediaIdentity.remap([item(in: root)], profile: changed, mount: root)[0].id)
  }
  @Test func distinctAccountsServersSharesAndProfilesCannotShareIdentity() throws {
    let root = URL(fileURLWithPath: "/tmp/mtv-mount")
    let profile = try SMBProfile(
      address: "nas/Movies", username: "viewer", guest: false, rememberPassword: false)
    let original = try SMBMediaIdentity.remap([item(in: root)], profile: profile, mount: root)[0].id
    for address in ["other/Movies", "nas:1445/Movies", "nas/OtherShare"] {
      var copy = profile
      copy.address = try SMBProfile.canonicalAddress(address)
      #expect(
        try SMBMediaIdentity.remap([item(in: root)], profile: copy, mount: root)[0].id != original)
    }
    var user = profile
    user.username = "someone-else"
    #expect(
      try SMBMediaIdentity.remap([item(in: root)], profile: user, mount: root)[0].id != original)
    let otherProfile = try SMBProfile(
      address: profile.address, username: profile.username, guest: false, rememberPassword: false)
    #expect(
      try SMBMediaIdentity.remap([item(in: root)], profile: otherProfile, mount: root)[0].id
        != original)
  }
  @Test func remountReusesStoredMatchAndPersistedProgress() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let a = root.appendingPathComponent("a")
    let b = root.appendingPathComponent("b")
    let profile = try SMBProfile(
      address: "nas/Movies", username: "", guest: true, rememberPassword: false)
    let first = try SMBMediaIdentity.remap([item(in: a)], profile: profile, mount: a)
    let second = try SMBMediaIdentity.remap([item(in: b)], profile: profile, mount: b)
    let match = MetadataStore(file: root.appendingPathComponent("matches.json"))
    let series = LibraryCatalog.build(first).root[0]
    let records = try match.set(
      targetID: series.id,
      candidate: MetadataCandidate(
        provider: .tvmaze,
        externalID: 84, kind: .series, title: "Matched series"))
    #expect(
      LibraryCatalog.build(MetadataStore.apply(records, to: second)).root[0].title
        == "Matched series")
    let scope = UUID()
    let progress = PlaybackResumeStore.isolated(scope: scope)
    defer { progress.removeTestDomain() }
    progress.save(42.5, for: first[0].id)
    #expect(PlaybackResumeStore.isolated(scope: scope).position(for: second[0].id) == 42.5)
    progress.save(.nan, for: first[0].id)
    #expect(progress.position(for: first[0].id) == 42.5)
  }
  @Test func rejectsEscapesRemoteURLsAndNonMediaItems() throws {
    let root = URL(fileURLWithPath: "/tmp/mtv-mount")
    let profile = try SMBProfile(
      address: "nas/Movies", username: "", guest: true, rememberPassword: false)
    for url in [
      "file:///tmp/mtv-mount-other/movie.mp4", "file:///tmp/mtv-mount/../outside.mp4",
      "file://other/tmp/mtv-mount/movie.mp4", "https://example.com/movie.mp4", root.absoluteString,
    ] {
      let invalid = MediaItem(id: "bad", title: "Invalid", url: url)
      #expect(throws: (any Error).self) {
        try SMBMediaIdentity.remap([invalid], profile: profile, mount: root)
      }
    }
    let folder = MediaItem(id: "folder", title: "Folder", url: root.absoluteString, kind: .folder)
    #expect(throws: (any Error).self) {
      try SMBMediaIdentity.remap([folder], profile: profile, mount: root)
    }
  }
}

import Foundation
import Testing
@testable import MTVCore

struct LocalSubtitlesTests {
  let cue = Data("1\n00:00:00,000 --> 00:00:08,000\nOwned subtitle text\n".utf8)
  func directory() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data().write(to: root.appendingPathComponent("Film.mp4"))
    return root
  }
  @Test func discoversOnlyMatchingRegularCaptionFilesInsideScope() throws {
    let root = try directory(), outside = try directory()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    for name in ["Film.srt", "Film.zh-Hans.ASS", "Film.en.vtt", "Film2.srt", "Other.srt", ".Film.srt"] { try cue.write(to: root.appendingPathComponent(name)) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Film.folder.srt"), withIntermediateDirectories: true)
    try cue.write(to: outside.appendingPathComponent("Film.srt"))
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Film.escape.srt"), withDestinationURL: outside.appendingPathComponent("Film.srt"))
    let result = try LocalSubtitles.discover(for: root.appendingPathComponent("Film.mp4"), access: .within(root))
    #expect(Set(result.candidates.map(\.filename)) == ["Film.srt", "Film.zh-Hans.ASS", "Film.en.vtt"])
    #expect(!result.limited)
    #expect(throws: (any Error).self) { try LocalSubtitles.discover(for: root.appendingPathComponent("Film.mp4"), access: .unrestricted) }
  }
  @Test func preparedSnapshotSurvivesOriginalChangeAndCleansOnlyOwnedDirectory() throws {
    let root = try directory()
    defer { try? FileManager.default.removeItem(at: root) }
    let original = root.appendingPathComponent("Film.srt"), storage = root.appendingPathComponent("owned-copies")
    try cue.write(to: original)
    let candidate = try LocalSubtitles.discover(for: root.appendingPathComponent("Film.mp4"), access: .within(root)).candidates[0]
    var prepared: PreparedLocalSubtitle? = try LocalSubtitles.prepare(candidate, access: .within(root), storage: storage)
    let copied = prepared!.url
    let copiedData = try Data(contentsOf: copied)
    #expect(copied != original && copiedData == cue)
    try Data("replacement".utf8).write(to: original)
    #expect(try Data(contentsOf: copied) == cue)
    prepared = nil
    #expect(!FileManager.default.fileExists(atPath: copied.deletingLastPathComponent().path))
    #expect(try String(contentsOf: original, encoding: .utf8) == "replacement")
    #expect(FileManager.default.fileExists(atPath: storage.path))
  }
  @Test func candidateCannotFollowReplacedSymlinkOutsideSelectedRoot() throws {
    let root = try directory(), outside = try directory()
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    let original = root.appendingPathComponent("Film.srt"), external = outside.appendingPathComponent("Film.srt")
    try cue.write(to: original); try cue.write(to: external)
    let candidate = try LocalSubtitles.discover(for: root.appendingPathComponent("Film.mp4"), access: .within(root)).candidates[0]
    try FileManager.default.removeItem(at: original)
    try FileManager.default.createSymbolicLink(at: original, withDestinationURL: external)
    #expect(throws: (any Error).self) { try LocalSubtitles.prepare(candidate, access: .within(root), storage: root.appendingPathComponent("copies")) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("copies").path))
  }
  @Test func candidateRejectsSelectedRootRedirectedAfterDiscovery() throws {
    let parent = try directory(), outside = try directory(), root = parent.appendingPathComponent("selected")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent); try? FileManager.default.removeItem(at: outside) }
    try Data().write(to: root.appendingPathComponent("Film.mp4")); try cue.write(to: root.appendingPathComponent("Film.srt"))
    try cue.write(to: outside.appendingPathComponent("Film.srt"))
    let candidate = try LocalSubtitles.discover(for: root.appendingPathComponent("Film.mp4"), access: .within(root)).candidates[0]
    try FileManager.default.moveItem(at: root, to: parent.appendingPathComponent("original-selected"))
    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
    #expect(throws: (any Error).self) { try LocalSubtitles.prepare(candidate, access: .within(root), storage: parent.appendingPathComponent("copies")) }
  }
  @Test func emptyOversizedFilesAndDirectoriesAreNotOffered() throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("Film.empty.srt"))
    let large = root.appendingPathComponent("Film.large.srt")
    FileManager.default.createFile(atPath: large.path, contents: nil)
    let file = try FileHandle(forWritingTo: large); try file.truncate(atOffset: UInt64(LocalSubtitles.maximumBytes + 1)); try file.close()
    let result = try LocalSubtitles.discover(for: root.appendingPathComponent("Film.mp4"), access: .within(root))
    #expect(result.candidates.isEmpty)
  }
  @Test func finiteCandidateBudgetDoesNotReadOtherDirectories() throws {
    let root = try directory(); defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<70 { try cue.write(to: root.appendingPathComponent("Film.\(index).srt")) }
    let result = try LocalSubtitles.discover(for: root.appendingPathComponent("Film.mp4"), access: .within(root))
    #expect(result.candidates.count == 64 && result.limited)
  }
}

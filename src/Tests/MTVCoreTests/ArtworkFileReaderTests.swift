import Darwin
import Foundation
import Testing
@testable import MTVCore

struct ArtworkFileReaderTests {
  @Test func acceptsInternalLinksButRejectsRetargetedLinksAndRevokedAccess() throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: parent) }
    let root = parent.appendingPathComponent("share"), outside = parent.appendingPathComponent("outside.jpg")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("inside.jpg"), link = root.appendingPathComponent("poster.jpg")
    let bytes = Data([1, 2, 3])
    try bytes.write(to: file); try Data([4, 5, 6]).write(to: outside)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    let scope = ArtworkFileAccess.within(URL(fileURLWithPath: try ArtworkFileReader.canonicalPath(root)))
    #expect(try ArtworkFileReader.read(link, access: scope) == bytes)
    #expect(try ArtworkFileReader.read(file) == bytes)
    #expect(throws: (any Error).self) { try ArtworkFileReader.read(link, access: .denied) }
    try FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    #expect(throws: (any Error).self) { try ArtworkFileReader.read(link, access: scope) }
    #expect(throws: (any Error).self) { try ArtworkFileReader.read(outside, access: scope) }
  }
  @Test func rejectsDirectoriesEmptyOversizedAndSpecialFilesWithoutBlocking() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let empty = root.appendingPathComponent("empty.jpg"), large = root.appendingPathComponent("large.jpg"), pipe = root.appendingPathComponent("pipe.jpg")
    try Data().write(to: empty); try Data().write(to: large)
    let handle = try FileHandle(forWritingTo: large); try handle.truncate(atOffset: 15_000_001); try handle.close()
    #expect(pipe.path.withCString { mkfifo($0, 0o600) } == 0)
    for url in [root, empty, large, pipe] {
      #expect(throws: (any Error).self) { try ArtworkFileReader.read(url) }
    }
  }
}

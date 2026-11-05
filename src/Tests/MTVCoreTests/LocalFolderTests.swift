import Foundation
import Testing

@testable import MTVCore

struct LocalFolderTests {
  @Test func validatesAddressesWithoutTreatingNetworkURLsAsLocalPaths() throws {
    #expect(try LocalFolders.address("~/Movies").path.hasSuffix("/Movies"))
    #expect(try LocalFolders.address("/Volumes/电影/../影片").path == "/Volumes/影片")
    for path in ["Movies", "smb://nas/Films", "https://example.com", "", "/tmp/a\0b"] {
      #expect(throws: (any Error).self) { try LocalFolders.address(path) }
    }
  }
  @Test func listsOnlyVisibleFoldersWithNaturalSortAndExplicitLimit() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    for name in ["Season 10", "Season 2", "Season 1", ".hidden", "Other.app"] {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    let file = root.appendingPathComponent("movie.mp4")
    try Data().write(to: file)
    let listing = try LocalFolders.list(root, limit: 2)
    #expect(listing.total == 3)
    #expect(listing.folders.map(\.lastPathComponent) == ["Season 1", "Season 2"])
    #expect(throws: (any Error).self) { try LocalFolders.list(file) }
  }
}

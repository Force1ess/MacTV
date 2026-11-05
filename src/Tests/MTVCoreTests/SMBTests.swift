import Foundation
import Testing

@testable import MTVCore

struct SMBTests {
  @Test func networkScanCannotFollowMediaMetadataOrArtworkOutsideMount() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mtv-smb-" + UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mtv-smb-outside-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    try Data().write(to: root.appendingPathComponent("Inside.mp4"))
    try Data().write(to: outside.appendingPathComponent("Outside.mp4"))
    try Data("<movie><title>Outside metadata</title></movie>".utf8).write(
      to: outside.appendingPathComponent("secret.nfo"))
    try Data().write(to: outside.appendingPathComponent("secret.jpg"))
    for (name, target) in [
      ("Outside.mp4", "Outside.mp4"), ("Inside.nfo", "secret.nfo"), ("poster.jpg", "secret.jpg"),
    ] {
      try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent(name),
        withDestinationURL: outside.appendingPathComponent(target))
    }
    let files = try LibraryScanner.scan(root: root, allowedResolvedRoot: root)
    #expect(files.count == 1)
    #expect(files.first?.title == "Inside")
    #expect(files.first?.poster == nil)
  }
  @Test func shareAndSubdirectoryAreSeparatedWithoutURLCredentials() throws {
    let location = try SMBLocation("SMB://nas.local:1445/电影/家庭 影片")
    #expect(location.shareURL.scheme == "smb")
    #expect(location.shareURL.host == "nas.local")
    #expect(location.shareURL.port == 1445)
    #expect(location.shareURL.path == "/电影")
    #expect(location.subdirectory == ["家庭 影片"])
    #expect(try SMBLocation("nas.local/Movies").shareURL.absoluteString == "smb://nas.local/Movies")
  }
  @Test func credentialsTraversalAndOtherSchemesCannotEnterSMBAddress() {
    for address in [
      "smb://user:secret@nas/share", "smb://user@nas/share", "https://nas/share",
      "file:///private", "smb://nas", "smb://nas/share/../private",
      "smb://nas/share/%2e%2e/private",
      "smb://nas/share%2fprivate", "smb://nas/share?password=secret", "smb://nas/share#secret",
      "smb://nas:65536/share", "smb://nas/share\nInjected",
    ] {
      #expect(throws: (any Error).self) { try SMBLocation(address) }
    }
  }
  @Test func directoryLinksCannotEscapeTheSelectedMount() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mtv-smb-" + UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(
      "mtv-smb-outside-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("escape"), withDestinationURL: outside)
    let location = try SMBLocation("nas/share/escape")
    #expect(throws: (any Error).self) { try location.directory(in: root) }
  }
}

import Foundation
import Testing

@testable import MTVCore

struct CoreTests {
  @Test func focusDoesNotEscapeGrid() {
    var grid = FocusGrid(rows: [4, 2, 5])
    grid.move(dx: 20, dy: 0)
    #expect(grid.column == 3)
    grid.move(dx: 0, dy: 1)
    #expect(grid.column == 1)
    grid.move(dx: -20, dy: -20)
    #expect(grid.row == 0)
    #expect(grid.column == 0)
  }
  @Test func networkPermissions() {
    let domains = ["api.bilibili.com"]
    for address in [
      "http://api.bilibili.com", "https://api.bilibili.com.evil.test", "https://127.0.0.1",
      "https://api.bilibili.com:9999", "https://user:pass@api.bilibili.com",
    ] {
      #expect(!NetworkPolicy.permits(URL(string: address)!, domains: domains))
    }
    #expect(
      NetworkPolicy.permits(
        URL(string: "https://api.bilibili.com/x/web-interface/popular")!, domains: domains))
  }
  @Test func scannerReadOnlyAndNFO() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("movie.mp4"))
    let nfo = Data("<movie><title>测试 &amp; 影片</title><year>2026</year><plot>简介</plot></movie>".utf8)
    try nfo.write(to: root.appendingPathComponent("movie.nfo"))
    let items = try LibraryScanner.scan(root: root)
    #expect(items.count == 1)
    #expect(items[0].title == "测试 & 影片")
    #expect(try Data(contentsOf: root.appendingPathComponent("movie.nfo")) == nfo)
  }
  @Test func unsupportedManifestVersion() throws {
    let data = Data(
      #"{"id":"test","name":"test","version":"1","apiVersion":3,"entry":"plugin.js","domains":[],"capabilities":[]}"#
        .utf8)
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
    #expect(throws: (any Error).self) { try manifest.validate() }
  }
}

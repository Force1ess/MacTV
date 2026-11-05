import Foundation
import Testing

@testable import MTVCore

struct PluginTests {
  @Test func watchlistCapabilityRequiresResolver() throws {
    var value = try JSONDecoder().decode(PluginManifest.self, from: manifest("test.watchlist"))
    value.capabilities = ["browse", "watchlist"]
    #expect(throws: (any Error).self) { try value.validate() }
    value.capabilities.append("resolve"); try value.validate()
  }
  @Test func lookupCapabilityRequiresResolver() throws {
    var value = try JSONDecoder().decode(PluginManifest.self, from: manifest("test.lookup"))
    value.capabilities.append("lookup")
    #expect(throws: (any Error).self) { try value.validate() }
    value.capabilities.append("resolve"); try value.validate()
  }
  @Test func internalLocalSourceCannotBeAPluginIdentityOrNormalizedContent() throws {
    let rogue = try JSONDecoder().decode(PluginManifest.self, from: manifest("local"))
    #expect(throws: (any Error).self) { try rogue.validate() }
    let file = MediaItem(id: "rogue", title: "Rogue", url: "file:///not-read-by-this-test.mp4", source: "local")
    #expect(throws: (any Error).self) { try PluginContentValidator.normalize([file], manifest: rogue) }
    let valid = try JSONDecoder().decode(PluginManifest.self, from: manifest("test.source"))
    #expect(try PluginContentValidator.normalize([file], manifest: valid).first?.source == "test.source")
  }
  @Test func partCollectionsRequireFolderCapabilityAndBoundedReferences() throws {
    var manifest = try JSONDecoder().decode(PluginManifest.self, from: manifest("test.parts"))
    var item = MediaItem(id: "video", title: "Video", source: "spoofed", collectionReference: "opaque-parts")
    #expect(throws: (any Error).self) { try PluginContentValidator.normalize([item], manifest: manifest) }
    manifest.capabilities.append("folders")
    let result = try PluginContentValidator.normalize([item], manifest: manifest)
    #expect(result.first?.collectionReference == "opaque-parts")
    #expect(result.first?.source == manifest.id)
    #expect(result.first?.isFolder == false)
    for reference in ["", String(repeating: "a", count: 513), "bad\nvalue"] {
      item.collectionReference = reference
      #expect(throws: (any Error).self) { try PluginContentValidator.normalize([item], manifest: manifest) }
    }
    item.collectionReference = "opaque-parts"; item.kind = .folder; item.reference = "folder"
    #expect(throws: (any Error).self) { try PluginContentValidator.normalize([item], manifest: manifest) }
    let old = Data(#"{"id":"old","title":"Old","subtitle":"","overview":"","source":"test.parts"}"#.utf8)
    #expect(try JSONDecoder().decode(MediaItem.self, from: old).collectionReference == nil)
  }
  @Test func postAuthorizationIsExactAndCannotTargetMutationEndpoints() throws {
    let endpoint = PluginPOSTEndpoint(host: "api.example.test", path: "/file/play")
    try endpoint.validate(domains: ["api.example.test"])
    #expect(endpoint.permits(URL(string: "https://api.example.test/file/play?pr=pc")!))
    for address in [
      "https://api.example.test/file/delete", "https://evil.test/file/play",
      "https://api.example.test.evil.test/file/play", "http://api.example.test/file/play",
      "https://api.example.test:9999/file/play", "https://api.example.test/file/play/../delete",
    ] {
      #expect(!endpoint.permits(URL(string: address)!))
    }
    for path in ["/file/../delete", "/file/%2e%2e/delete", "/file/play?path=delete", "/file//play"]
    {
      #expect(throws: (any Error).self) {
        try PluginPOSTEndpoint(host: "api.example.test", path: path).validate(domains: [
          "api.example.test"
        ])
      }
    }
  }
  @Test func foldersRequireCapabilityAndOpaqueReferenceWithoutLocalURL() throws {
    var manifest = try JSONDecoder().decode(PluginManifest.self, from: manifest("test.folders"))
    let folder = MediaItem(
      id: "folder", title: "Folder", source: "local", reference: "opaque-id", kind: .folder)
    #expect(throws: (any Error).self) {
      try PluginContentValidator.normalize([folder], manifest: manifest)
    }
    manifest.capabilities.append("folders")
    try manifest.validate()
    let result = try PluginContentValidator.normalize([folder], manifest: manifest)
    #expect(result.first?.source == manifest.id)
    #expect(result.first?.isFolder == true)
    var local = folder
    local.url = "file:///Users/private"
    #expect(throws: (any Error).self) {
      try PluginContentValidator.normalize([local], manifest: manifest)
    }
    var missing = folder
    missing.reference = nil
    #expect(throws: (any Error).self) {
      try PluginContentValidator.normalize([missing], manifest: manifest)
    }
  }
  private func manifest(_ id: String, developerOnly: Bool = false) -> Data {
    try! JSONSerialization.data(withJSONObject: [
      "id": id, "name": "Example", "version": "1", "apiVersion": 1, "entry": "plugin.js",
      "domains": [], "capabilities": ["browse"], "presentation": ["developerOnly": developerOnly],
    ])
  }
  @Test func catalogFindsNewModuleWithoutSwiftRegistration() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let plugin = root.appendingPathComponent("new-module")
    try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
    try manifest("test.new-module").write(to: plugin.appendingPathComponent("manifest.json"))
    try Data("const plugin={handle(){return {items:[]}}}".utf8).write(
      to: plugin.appendingPathComponent("plugin.js"))
    let result = try PluginCatalog.load(root: root)
    #expect(result.plugins.map(\.id) == ["test.new-module"])
    #expect(result.issues.isEmpty)
  }
  @Test func developerModulesRequireExplicitMode() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let plugin = root.appendingPathComponent("dev")
    try FileManager.default.createDirectory(at: plugin, withIntermediateDirectories: true)
    try manifest("test.dev", developerOnly: true).write(
      to: plugin.appendingPathComponent("manifest.json"))
    try Data("const plugin={handle(){return {items:[]}}}".utf8).write(
      to: plugin.appendingPathComponent("plugin.js"))
    #expect(try PluginCatalog.load(root: root).plugins.isEmpty)
    #expect(try PluginCatalog.load(root: root, developerMode: true).plugins.count == 1)
  }
  @Test func catalogRejectsExternalSymlink() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("escape"), withDestinationURL: outside)
    let result = try PluginCatalog.load(root: root)
    #expect(result.plugins.isEmpty)
    #expect(result.issues.count == 1)
  }
  @Test func playbackSubdomainsHaveBoundary() {
    #expect(
      NetworkPolicy.permitsPlayback(
        URL(string: "https://cdn.bilivideo.com/video.mp4")!, domains: ["bilivideo.com"]))
    #expect(
      !NetworkPolicy.permitsPlayback(
        URL(string: "https://bilivideo.com.attacker.test/video.mp4")!, domains: ["bilivideo.com"]))
    #expect(
      !NetworkPolicy.permitsPlayback(
        URL(string: "https://evilbilivideo.com/video.mp4")!, domains: ["bilivideo.com"]))
    #expect(
      !NetworkPolicy.permitsPlayback(
        URL(string: "file:///tmp/test.mp4")!, domains: ["bilivideo.com"]))
  }
  @Test func pluginCannotSpoofLocalSourceOrReadLocalArtwork() throws {
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: manifest("test.content"))
    let spoofed = MediaItem(id: "1", title: "Item", source: "local")
    let normalized = try PluginContentValidator.normalize([spoofed, spoofed], manifest: manifest)
    #expect(normalized.count == 1)
    #expect(normalized[0].source == "test.content")
    let fakeSeries = MediaItem(id: "series", title: "Fake", kind: .series)
    #expect(throws: (any Error).self) {
      try PluginContentValidator.normalize([fakeSeries], manifest: manifest)
    }
    let spoofedMetadata = MediaItem(
      id: "metadata", title: "Fake",
      localMetadata: LocalMediaMetadata(
        seriesTitle: "Local", seriesRoot: "/private", season: 1, episode: 1))
    #expect(
      try PluginContentValidator.normalize([spoofedMetadata], manifest: manifest).first?
        .localMetadata == nil)
    let artwork = MediaItem(id: "2", title: "Bad", poster: "file:///private/fixture/private.png")
    #expect(throws: (any Error).self) {
      try PluginContentValidator.normalize([artwork], manifest: manifest)
    }
  }
}

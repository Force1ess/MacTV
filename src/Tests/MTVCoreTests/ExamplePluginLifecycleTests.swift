import Foundation
import Testing
@testable import MTVCore

struct ExamplePluginLifecycleTests {
  private func example(_ root: URL, name: String, version: String = "1.0") throws {
    let folder = root.appendingPathComponent(name)
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
    let manifest: [String:Any] = ["id":"example."+name,"name":name,"version":version,"apiVersion":1,"entry":"plugin.js","domains":[],"capabilities":["browse"]]
    try JSONSerialization.data(withJSONObject:manifest).write(to:folder.appendingPathComponent("manifest.json"))
    try Data("const plugin={handle(){return {items:[]}}};".utf8).write(to:folder.appendingPathComponent("plugin.js"))
  }
  @Test func shippedExamplesAreOrdinaryManagedPackagesAndNeverResurrectAfterRemoval() async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:base) }
    let source = base.appendingPathComponent("examples"), managed = base.appendingPathComponent("managed")
    try example(source,name:"gallery"); try example(source,name:"steam")
    let store = PluginPackageStore(root:managed)
    try await store.installExamplesOnce(from:source)
    let first = try await store.catalog().plugins
    #expect(first.count == 2)
    #expect(first.allSatisfy { $0.directory.path.hasPrefix(managed.path+"/") })
    try await store.setEnabled("example.gallery",false)
    try await store.remove("example.steam")
    let restarted = PluginPackageStore(root:managed)
    try await restarted.installExamplesOnce(from:source)
    #expect(try await restarted.catalog().plugins.isEmpty)
    let installed = try await restarted.installed()
    #expect(installed.count == 1 && !installed[0].enabled)
    try await restarted.setEnabled("example.gallery",true)
    #expect(try await restarted.catalog().plugins.count == 1)
    try example(source,name:"gallery",version:"3.0")
    try await restarted.installExamplesOnce(from:source)
    #expect(try await restarted.installed()[0].manifest.version == "1.0")
    let update = try await restarted.prepare(directory:source.appendingPathComponent("gallery"))
    _ = try await restarted.approve(update.id)
    #expect(try await restarted.catalog().plugins[0].manifest.version == "3.0")
    try await restarted.remove("example.gallery")
    try await restarted.installExamplesOnce(from:source)
    #expect(try await restarted.installed().isEmpty)
  }
}

import Foundation
import Testing
@testable import MTVCore

private func fixtureGit(_ arguments: [String], at directory: URL) throws {
  let child=Process(); child.executableURL=URL(fileURLWithPath:"/usr/bin/git")
  child.arguments=["-C",directory.path,"-c","core.hooksPath=/dev/null","-c","commit.gpgsign=false","-c","user.name=Plugin Fixture","-c","user.email=fixture@example.invalid"]+arguments
  child.standardInput=FileHandle.nullDevice; child.standardOutput=FileHandle.nullDevice; child.standardError=FileHandle.nullDevice
  try child.run(); child.waitUntilExit()
  guard child.terminationStatus==0 else { throw MTVError.message("Fixture Git failed") }
}
private func fixturePackage(_ repository: URL, version: String, script: String) throws {
  let package=repository.appendingPathComponent("plugin")
  try FileManager.default.createDirectory(at:package,withIntermediateDirectories:true)
  let manifest: [String:Any] = ["id":"community.fixture","name":"Fixture","version":version,"apiVersion":1,"entry":"plugin.js","domains":[],"capabilities":["browse"]]
  try JSONSerialization.data(withJSONObject:manifest).write(to:package.appendingPathComponent("manifest.json"))
  try Data(script.utf8).write(to:package.appendingPathComponent("plugin.js"))
  let catalog: [String:Any] = ["schemaVersion":2,"id":"fixture","name":"Fixture","plugins":[["id":"community.fixture","name":"Fixture","version":version,"apiVersion":1,"directory":"plugin"]]]
  try JSONSerialization.data(withJSONObject:catalog).write(to:repository.appendingPathComponent("catalog.json"))
  try fixtureGit(["add","."],at:repository); try fixtureGit(["commit","--quiet","-m",version],at:repository)
}

struct PluginGitSourceTests {
  @Test func futureAPICanBeListedButCannotBeInstalled() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    let data: [String:Any] = ["schemaVersion":2,"id":"fixture","name":"Fixture","plugins":[["id":"community.future","name":"Future","version":"1","apiVersion":3,"directory":"plugin"]]]
    let catalog=try PluginSourceCatalog(data:JSONSerialization.data(withJSONObject:data))
    #expect(!catalog.plugins[0].isCompatible)
    let source=PluginSource(id:"fixture",name:"Fixture",repository:root.appendingPathComponent("remote").absoluteString)
    let client=PluginSourceClient(root:root.appendingPathComponent("cache"),testRoot:root)
    let destination=root.appendingPathComponent("stage")
    await #expect(throws: Error.self) { try await client.stage(catalog.plugins[0],source:source,revision:String(repeating:"0",count:40),into:destination) }
    #expect(!FileManager.default.fileExists(atPath:destination.path))
  }
  @Test func clonesFetchesAndStagesAnImmutableCommitWithoutExecutingPluginCode() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let repository=root.appendingPathComponent("remote")
    try FileManager.default.createDirectory(at:repository,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    try fixtureGit(["init","--quiet","--initial-branch=main"],at:repository)
    try fixturePackage(repository,version:"1.0",script:"throw Error('OLD must not execute');")
    let source=PluginSource(id:"fixture",name:"Fixture",repository:repository.absoluteString)
    let client=PluginSourceClient(root:root.appendingPathComponent("cache"),testRoot:root)
    let first=try await client.catalog(source:source)
    try fixturePackage(repository,version:"2.0",script:"throw Error('NEW must not execute');")
    let second=try await client.catalog(source:source)
    #expect(first.revision != second.revision)
    let old=root.appendingPathComponent("old"), new=root.appendingPathComponent("new")
    #expect(try await client.stage(first.catalog.plugins[0],source:source,revision:first.revision,into:old).version=="1.0")
    #expect(try await client.stage(second.catalog.plugins[0],source:source,revision:second.revision,into:new).version=="2.0")
    #expect(try String(contentsOf:old.appendingPathComponent("plugin.js"),encoding:.utf8).contains("OLD"))
    #expect(try String(contentsOf:new.appendingPathComponent("plugin.js"),encoding:.utf8).contains("NEW"))
    let packages=PluginPackageStore(root:root.appendingPathComponent("managed"))
    let review=try await packages.prepare(directory:old,origin:PluginInstallationOrigin(kind:"git",source:source,revision:first.revision))
    _ = try await packages.approve(review.id)
    let origin=try await PluginPackageStore(root:root.appendingPathComponent("managed")).installed().first?.origin
    #expect(origin?.revision==first.revision && origin?.repository==source.repository)
    let objects=root.appendingPathComponent("cache/fixture.git")
    #expect(!FileManager.default.fileExists(atPath:objects.appendingPathComponent("plugin").path))
  }
  @Test func rejectsSymlinkPayloadAndRemovesPartialStaging() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), repository=root.appendingPathComponent("remote")
    try FileManager.default.createDirectory(at:repository,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    try fixtureGit(["init","--quiet","--initial-branch=main"],at:repository)
    try fixturePackage(repository,version:"1.0",script:"safe")
    let script=repository.appendingPathComponent("plugin/plugin.js")
    try FileManager.default.removeItem(at:script)
    try FileManager.default.createSymbolicLink(at:script,withDestinationURL:root.appendingPathComponent("private"))
    try fixtureGit(["add","."],at:repository); try fixtureGit(["commit","--quiet","-m","link"],at:repository)
    let source=PluginSource(id:"fixture",name:"Fixture",repository:repository.absoluteString)
    let client=PluginSourceClient(root:root.appendingPathComponent("cache"),testRoot:root)
    let snapshot=try await client.catalog(source:source), output=root.appendingPathComponent("stage")
    await #expect(throws: Error.self) { try await client.stage(snapshot.catalog.plugins[0],source:source,revision:snapshot.revision,into:output) }
    #expect(!FileManager.default.fileExists(atPath:output.path))
  }
  @Test func sourceSettingsPersistRemovalAndNeverStoreSSHCredentials() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let source=PluginSource(id:"official",name:"Official",repository:"git@github.com:example/plugins.git")
    let store=PluginSourceStore(root:root,defaults:[source])
    #expect(try await store.sources()==[source])
    try await store.setEnabled(source.id,false)
    try await store.setReference(source.id,"stable")
    let restarted=PluginSourceStore(root:root,defaults:[source])
    #expect(try await restarted.sources()[0].reference=="stable")
    #expect(try await restarted.sources()[0].enabled==false)
    try await restarted.remove(source.id)
    #expect(try await PluginSourceStore(root:root,defaults:[source]).sources().isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath:root.path)==["sources.json"])
    let permission=try FileManager.default.attributesOfItem(atPath:root.appendingPathComponent("sources.json").path)[.posixPermissions] as? NSNumber
    #expect(permission?.intValue==0o600)
  }
  @Test func rejectsShellTransportsPasswordsTraversalAndUnsafeRefs() throws {
    #expect(PluginSource.permits("git@github-alias:owner/plugins.git"))
    #expect(PluginSource.permits("ssh://git@example.invalid:22/owner/plugins.git"))
    #expect(PluginSource.permits("https://example.invalid/owner/plugins.git"))
    for address in ["ext::touch /tmp/unwanted","https://user:password@example.invalid/plugins.git","git@host:../escape.git","ssh://host/plugins.git?token=secret","-u/bin/sh"] { #expect(!PluginSource.permits(address)) }
    for reference in ["--upload-pack=sh","main:refs/other","../escape","main@{0}"] { #expect(!PluginSource.validReference(reference)) }
    let payload: [String:Any] = ["schemaVersion":2,"id":"fixture","name":"Fixture","plugins":[["id":"community.fixture","name":"Fixture","version":"1","apiVersion":1,"directory":"../escape"]]]
    #expect(throws: Error.self) { try PluginSourceCatalog(data:JSONSerialization.data(withJSONObject:payload)) }
  }
  @Test func missingBranchIsReportedWithoutDiscardingInstalledSourceSettings() async throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), repository=root.appendingPathComponent("remote")
    try FileManager.default.createDirectory(at:repository,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    try fixtureGit(["init","--quiet","--initial-branch=main"],at:repository)
    try fixturePackage(repository,version:"1",script:"safe")
    let source=PluginSource(id:"fixture",name:"Fixture",repository:repository.absoluteString,reference:"missing")
    let client=PluginSourceClient(root:root.appendingPathComponent("cache"),testRoot:root)
    await #expect(throws: PluginGitFailure.self) { try await client.catalog(source:source) }
    #expect(!FileManager.default.fileExists(atPath:root.appendingPathComponent("cache/fixture.git").path))
  }
}

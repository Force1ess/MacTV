import Foundation
import Testing
@testable import MTVCore

private final class NativeBlockedRead: @unchecked Sendable {
  let started:AsyncStream<Void>, blocked=DispatchSemaphore(value:0)
  private let start:AsyncStream<Void>.Continuation
  private let lock=NSLock(); private var done=false
  init() { let signal=AsyncStream<Void>.makeStream(); started=signal.stream; start=signal.continuation }
  func didStart() { start.yield(()); start.finish() }
  func release() { lock.lock(); done=true; lock.unlock(); start.finish(); blocked.signal() }
  var released: Bool { lock.lock(); defer { lock.unlock() }; return done }
}

struct NativeLibraryTests {
  @Test(.timeLimit(.minutes(1))) func cancellingNativeWorkReturnsBeforeAnUninterruptibleReadCompletes() async throws {
    let fixture=NativeBlockedRead(), cancellation=NativeLibraryCancellation()
    let task=Task { try await NativeLibraryWork.run(cancellation:cancellation) {
      fixture.didStart(); fixture.blocked.wait(); return Data([1])
    } }
    defer { task.cancel(); fixture.release() }
    try await withTaskCancellationHandler(operation:{
      var started=fixture.started.makeAsyncIterator()
      try #require(await started.next() != nil)
      task.cancel()
      await #expect(throws: CancellationError.self) { try await task.value }
      #expect(!fixture.released)
    },onCancel:{ task.cancel(); fixture.release() })
  }
  @Test func releasingOneExperienceRemovesItsFileGrantWithoutAffectingAnother() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:root) }
    try Data([0]).write(to:root.appendingPathComponent("photo.jpg"))
    let library = NativeLibrary()
    for id in ["fixture.one","fixture.two"] { try library.configure(pluginID:id,roots:[root]) }
    let page = try JSONDecoder().decode(PluginPage.self,from:library.request(pluginID:"fixture.one",services:["pictures"],service:"pictures",input:["reference":"0:"]))
    let reference = try #require(page.items.first?.reference)
    library.release(pluginID:"fixture.one")
    #expect(throws: Error.self) { try library.asset(pluginID:"fixture.one",services:["pictures"],reference:reference,kind:.photo) }
    #expect(try library.asset(pluginID:"fixture.two",services:["pictures"],reference:reference,kind:.photo).lastPathComponent == "photo.jpg")
  }
  @Test func cancellingNativeReaderOnlyTerminatesItsOwnedProcess() throws {
    let cancelled = NativeLibraryCancellation(); cancelled.cancel()
    #expect(throws: CancellationError.self) {
      try NativeLibrary().request(pluginID:"fixture.music",services:["music"],service:"music",input:[:],cancellation:cancelled)
    }
    let operation = NativeLibraryCancellation(), child = Process()
    child.executableURL = URL(fileURLWithPath:"/bin/sleep"); child.arguments = ["5"]
    try operation.start(child); operation.cancel(); child.waitUntilExit()
    #expect(child.terminationReason == .uncaughtSignal)
  }
  @Test func pictureBrowserRespectsSelectedRootAndDoesNotFollowEscapingLinks() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let root = base.appendingPathComponent("album"), outside = base.appendingPathComponent("outside")
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    try FileManager.default.createDirectory(at:outside,withIntermediateDirectories:true)
    defer { try? FileManager.default.removeItem(at:base) }
    try Data([0]).write(to:root.appendingPathComponent("photo.jpg"))
    try Data([0]).write(to:root.appendingPathComponent("movie.mp4"))
    try Data([0]).write(to:outside.appendingPathComponent("private.jpg"))
    try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("escape"),withDestinationURL:outside)
    let library = NativeLibrary()
    try library.configure(pluginID:"fixture.gallery",roots:[root])
    let data = try library.request(pluginID:"fixture.gallery",services:["pictures"],service:"pictures",input:["reference":"0:"])
    let page = try JSONDecoder().decode(PluginPage.self,from:data)
    #expect(page.items.count == 1 && page.items[0].kind == .photo)
    let url = try library.asset(pluginID:"fixture.gallery",services:["pictures"],reference:page.items[0].reference!,kind:.photo)
    #expect(url.lastPathComponent == "photo.jpg")
    let access = library.fileAccess(pluginID:"fixture.gallery",reference:page.items[0].reference!,url:url)
    if case .within(let boundary) = access { #expect(boundary.path == (try ScopedFileReader.canonicalPath(boundary))) }
    #expect(try ScopedFileReader.read(url,access:access,maximumBytes:15_000_000) == Data([0]))
    let escape = "0:" + Data("../outside/private.jpg".utf8).base64EncodedString()
    #expect(throws: Error.self) { try library.asset(pluginID:"fixture.gallery",services:["pictures"],reference:escape,kind:.photo) }
    #expect(throws: Error.self) { try library.request(pluginID:"fixture.gallery",services:[],service:"pictures",input:[:]) }
    #expect(throws: Error.self) { try library.asset(pluginID:"other.plugin",services:["pictures"],reference:page.items[0].reference!,kind:.photo) }
  }
  @Test func scriptsCannotInjectLocalMediaURLsThroughNativeKinds() throws {
    let manifest = try JSONDecoder().decode(PluginManifest.self,from:Data(#"{"id":"fixture.gallery","name":"Gallery","version":"1","apiVersion":1,"entry":"plugin.js","domains":[],"capabilities":["browse","library"],"nativeLibraries":["pictures"]}"#.utf8))
    let rogue = MediaItem(id:"rogue",title:"Rogue",url:"file:///not-read.jpg",reference:"0:",kind:.photo)
    #expect(throws: Error.self) { try PluginContentValidator.normalize([rogue],manifest:manifest) }
    var invalid = manifest;invalid.nativeLibraries = ["credentials"]
    #expect(throws: Error.self) { try invalid.validate() }
  }
}

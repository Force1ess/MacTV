import Darwin
import Foundation
import MPVBridge
import Testing

struct MPVBridgeTests {
  @Test(arguments:[false,true]) func drainsEventsAndReadsCachedPropertiesWithoutSynchronousQueries(diagnostics:Bool) async throws {
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    defer { try? FileManager.default.removeItem(at:directory) }
    let source=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Fixtures/MPVClientFixture.c")
    let library=directory.appendingPathComponent("owned-mpv.dylib")
    let compiler=Process(); compiler.executableURL=URL(fileURLWithPath:"/usr/bin/cc")
    compiler.arguments=["-dynamiclib","-pthread",source.path,"-o",library.path]
    compiler.standardOutput=FileHandle.nullDevice; compiler.standardError=FileHandle.nullDevice
    let status:Int32 = try await withCheckedThrowingContinuation { continuation in
      compiler.terminationHandler = { process in continuation.resume(returning:process.terminationStatus) }
      do { try compiler.run() }
      catch { compiler.terminationHandler=nil; continuation.resume(throwing:error) }
    }
    try #require(status==0)
    let loaded=try #require(dlopen(library.path,RTLD_NOW|RTLD_LOCAL))
    defer { dlclose(loaded) }
    let player=try #require(mtv_mpv_create(library.path))
    var closed=false
    defer { if !closed { mtv_mpv_destroy(player) } }
    if diagnostics { mtv_mpv_enable_diagnostics(player); mtv_mpv_enable_stage_logs(player) }
    try #require(mtv_mpv_initialize(player)==0)
    func cached(_ key:String) -> String {
      var value=[CChar](repeating:0,count:256)
      guard mtv_mpv_cached_property(player,key,&value,Int32(value.count))==0 else { return "" }
      return String(cString:value)
    }
    for _ in 0..<100 {
      if cached("estimated-frame-number")=="42" { break }
      try await Task.sleep(for:.milliseconds(10))
    }
    #expect(cached("time-pos")=="1.25")
    #expect(cached("video-params/w")=="1920")
    #expect(cached("estimated-frame-number")=="42") // Native synchronous getter returns 999.
    func command(_ name:String) {
      let name=strdup(name); defer { free(name) }
      let arguments:[UnsafePointer<CChar>?]=[UnsafePointer(name),nil]
      #expect(arguments.withUnsafeBufferPointer { mtv_mpv_command(player,$0.baseAddress) }==0)
    }
    func asyncGets() -> Int {
      var value=[CChar](repeating:0,count:64)
      guard mtv_mpv_property(player,"fixture.async-gets",&value,Int32(value.count))==0 else { return -1 }
      return Int(String(cString:value)) ?? -1
    }
    let previousGets=asyncGets()
    command("fixture-start")
    for _ in 0..<100 { if asyncGets()>previousGets && cached("estimated-frame-number")=="42" { break }; try await Task.sleep(for:.milliseconds(10)) }
    #expect(asyncGets()>previousGets)
    #expect(cached("current-vo")=="gpu-next" && cached("pause")=="no")
    command("fixture-eof")
    for _ in 0..<100 { if cached("eof-reached")=="yes" && cached("pause")=="yes" { break }; try await Task.sleep(for:.milliseconds(10)) }
    #expect(cached("eof-reached")=="yes")
    #expect(cached("duration")=="10" && cached("time-pos")=="1.25")
    command("fixture-seek")
    for _ in 0..<100 { if cached("eof-reached")=="no" { break }; try await Task.sleep(for:.milliseconds(10)) }
    #expect(cached("eof-reached")=="no")
    command("fixture-error")
    for _ in 0..<100 { if mtv_mpv_playback_error(player)<0 { break }; try await Task.sleep(for:.milliseconds(10)) }
    #expect(mtv_mpv_playback_error(player)==(-13))
    var trace=[CChar](repeating:0,count:4096)
    try #require(mtv_mpv_startup_trace(player,&trace,Int32(trace.count))==0)
    let text=String(cString:trace)
    let events=try #require(JSONSerialization.jsonObject(with:Data(text.utf8)) as? [[String:Double]])
    #expect(diagnostics ? events.contains(where:{$0["event"]==8}):events.isEmpty)
    #expect(!text.contains("owned.invalid") && !text.contains("fixture-secret"))
    #expect(events.allSatisfy { Set($0.keys)==["event","ms"] })
    mtv_mpv_destroy(player); closed=true
    typealias Getter = @convention(c) () -> Int32
    let unsafe=unsafeBitCast(try #require(dlsym(loaded,"fixture_unsafe_destroys")),to:Getter.self)
    let wakeups=unsafeBitCast(try #require(dlsym(loaded,"fixture_wakeups")),to:Getter.self)
    #expect(unsafe()==0 && wakeups()>0)
  }
}

import Foundation
import Testing
@testable import MTVCore

private actor RPCGate {
  private var open=false
  private var waiters: [CheckedContinuation<Void,Never>]=[]
  func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
  func release() { open=true; let values=waiters; waiters=[]; for value in values { value.resume() } }
}

private func invokeAsyncFixture(_ script: String, cancel: @escaping @Sendable () -> Void = {}, handler: @escaping @Sendable (PluginRPCRequest) async throws -> Data) async throws -> [String:Any] {
  let root=TestProject.root
  let child=Process(), input=Pipe(), output=Pipe()
  child.executableURL=root.appendingPathComponent(".build/debug/MTVPluginHost"); child.arguments=["--brokered"]
  child.standardInput=input; child.standardOutput=output; child.standardError=FileHandle.nullDevice
  let exitObservation = try ProcessExitObservation(child)
  try child.run()
  let watchdog=DispatchWorkItem { if child.isRunning { child.terminate() } }
  DispatchQueue.global().asyncAfter(deadline:.now()+10,execute:watchdog)
  defer {
    watchdog.cancel(); try? input.fileHandleForWriting.close()
    if child.isRunning { child.terminate() }; try? output.fileHandleForReading.close()
  }
  let manifest: [String:Any] = ["id":"fixture.async","name":"Async Fixture","version":"1","apiVersion":2,"entry":"plugin.js","domains":[],"capabilities":["browse","library"],"nativeLibraries":["photos"]]
  do {
    try PluginChannel.write(["approvedManifest":manifest,"scriptBase64":Data(script.utf8).base64EncodedString(),"action":"browse","input":[:],"sessionAvailable":false],to:input.fileHandleForWriting,maximum:1_600_000)
    let session=PluginAsyncRPC(reader:output.fileHandleForReading,writer:input.fileHandleForWriting)
    let result=try await session.run(handler:handler,cancel:cancel,terminate:{ if child.isRunning { child.terminate() } })
    try input.fileHandleForWriting.close()
    let exit = await exitObservation.wait()
    #expect(exit.status == 0 && !exit.signalled)
    return result
  } catch {
    if child.isRunning { child.terminate() }
    try? input.fileHandleForWriting.close()
    _ = await exitObservation.wait()
    throw error
  }
}

struct PluginAsyncRPCTests {
  @Test func actualChildExitPreservesStatusForConcurrentAndLateWaiters() async throws {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sh"); child.arguments = ["-c", "exit 17"]
    let observation = try ProcessExitObservation(child)
    try child.run()
    async let first = observation.wait()
    async let second = observation.wait()
    let values = await [first, second, observation.wait()]
    #expect(values.allSatisfy { $0.status == 17 && !$0.signalled })
    #expect(!child.isRunning)
    #expect(throws: Error.self) { try ProcessExitObservation(child) }
  }

  @Test func promiseAllReceivesOutOfOrderRepliesWithoutSerialDeadlock() async throws {
    let gate=RPCGate()
    let script="""
      const plugin={async handle(){
        const slow=host.library('photos',{key:'slow'});
        const fast=host.library('photos',{key:'fast'}).then(async value=>{await host.library('photos',{key:'release'});return value;});
        const values=await Promise.all([slow,fast]);return {items:[],keys:values.map(value=>value.key),api:host.apiVersion};
      }};
      """
    let result=try await invokeAsyncFixture(script,cancel:{ Task { await gate.release() } }) { request in
      let input=try JSONSerialization.jsonObject(with:Data(request.options.utf8)) as! [String:String]
      let key=input["key"]!
      if key=="slow" { await gate.wait() }
      if key=="release" { await gate.release() }
      return try JSONSerialization.data(withJSONObject:["key":key])
    }
    #expect(result["keys"] as? [String]==["slow","fast"])
    #expect(result["api"] as? Int==2)
  }
  @Test func rejectedNativeCallCanBeCaughtAndFollowedByAnotherCall() async throws {
    let result=try await invokeAsyncFixture("const plugin={async handle(){let caught=false;try{await host.library('photos',{key:'error'});}catch(e){caught=true;}const next=await host.library('photos',{key:'ok'});return {items:[],caught,next:next.key};}};") { request in
      if request.options.contains("error") { throw MTVError.message("Owned fixture rejection") }
      return Data(#"{"key":"ok"}"#.utf8)
    }
    #expect(result["caught"] as? Bool==true); #expect(result["next"] as? String=="ok")
  }
  @Test func cancellingInvocationTerminatesItsWorkerAndPendingNativeCall() async throws {
    let started=RPCGate()
    let task=Task {
      defer { Task { await started.release() } }
      return try await invokeAsyncFixture("const plugin={async handle(){await host.library('photos',{});return {items:[]};}};") { _ in
        await started.release(); try await Task.sleep(for:.seconds(100)); return Data()
      }
    }
    await started.wait(); task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }
  @Test func malformedIDsLegacyFramesAndOversizedInputsAreRejected() throws {
    let valid: [String:Any] = ["type":"libraryAsync","id":1,"service":"photos","input":"{}"]
    #expect(try PluginRPCRequest(frame:valid,expectedID:1).id==1)
    #expect(throws: Error.self) { try PluginRPCRequest(frame:valid,expectedID:2) }
    var legacy=valid; legacy["type"]="library"
    #expect(throws: Error.self) { try PluginRPCRequest(frame:legacy,expectedID:1) }
    var oversized=valid; oversized["input"]=String(repeating:"a",count:16_385)
    #expect(throws: Error.self) { try PluginRPCRequest(frame:oversized,expectedID:1) }
  }
}

import Foundation
import JavaScriptCore
import MTVCore

private final class AsyncPluginReplies: @unchecked Sendable {
  private let lock=NSLock()
  private var frames: [[String:Any]]=[]
  private var failure: String?
  private var stopped=false
  func start() {
    DispatchQueue.global(qos:.userInitiated).async { [self] in
      do {
        while let frame=try PluginChannel.read(from:.standardInput,maximum:3_000_000) {
          guard frame["type"] as? String=="reply", Set(frame.keys)==["type","id","payload"],
            let id=frame["id"] as? Int, (1...64).contains(id), let encoded=frame["payload"] as? String,
            let data=Data(base64Encoded:encoded), data.count<=2_100_000,
            let text=String(data:data,encoding:.utf8) else { throw MTVError.message("Invalid async broker reply") }
          lock.lock()
          if stopped { lock.unlock(); return }
          frames.append(["id":id,"text":text]); lock.unlock()
        }
        lock.lock(); if !stopped { failure="Async broker closed before completion" }; lock.unlock()
      } catch { lock.lock(); failure="Invalid async broker channel"; lock.unlock() }
    }
  }
  func next() throws -> [String:Any]? {
    lock.lock(); defer { lock.unlock() }
    if let failure { throw MTVError.message(failure) }
    return frames.isEmpty ? nil:frames.removeFirst()
  }
  func stop() { lock.lock(); stopped=true; frames.removeAll(); lock.unlock() }
}

/// JS always stays on this thread; only framed pipe reads use a background
/// reader. Promise jobs and out-of-order native responses share this event loop.
func prepareAsyncPlugin(context: JSContext, available: Bool, exception: @escaping () -> String?) throws -> (() throws -> String) {
  var number=0
  let send: @convention(block) (String,String,String) -> Int = { kind, argument, options in
    guard number<64, ["libraryAsync","fetchAsync"].contains(kind), argument.utf8.count<=16_384,
      options.utf8.count<=(kind=="libraryAsync" ? 16_384:131_072) else { return -1 }
    number += 1
    do {
      let frame: [String:Any] = kind=="libraryAsync" ? ["type":kind,"id":number,"service":argument,"input":options] : ["type":kind,"id":number,"url":argument,"options":options]
      try PluginChannel.write(frame,to:.standardOutput,maximum:262_144); return number
    } catch { return -1 }
  }
  var completed: String?, rejected: String?
  let finish: @convention(block) (String,String) -> Void = { result,error in
    guard completed==nil && rejected==nil else { return }
    if error.isEmpty { completed=result } else { rejected=String(error.prefix(4096)) }
  }
  context.setObject(send,forKeyedSubscript:"__sendAsync" as NSString)
  context.setObject(finish,forKeyedSubscript:"__finishAsync" as NSString)
  context.evaluateScript("""
    const __pendingRPC = new Map();
    function __callAsync(kind, argument, input) {
      return new Promise((resolve,reject)=>{
        const id=__sendAsync(kind,String(argument),JSON.stringify(input||{}));
        if(id<1){reject(Error('Invalid host request or request budget exceeded'));return;}
        __pendingRPC.set(id,{resolve,reject,kind});
      });
    }
    function __deliverAsync(id,text) {
      const pending=__pendingRPC.get(id);
      if(!pending)throw Error('Unexpected async response identity');
      __pendingRPC.delete(id);
      try {
        const response=JSON.parse(text);
        if(response.error)throw Error(response.error);
        if(pending.kind==='fetchAsync') {
          if(response.status!==200)throw Error('HTTP '+response.status+(Number.isSafeInteger(response.providerCode)?' · '+response.providerCode:''));
          pending.resolve(JSON.parse(response.body));
        } else pending.resolve(response);
      } catch(error){pending.reject(error);}
    }
    const host=Object.freeze({apiVersion:2,sessionAvailable:\(available ? "true":"false"),
      limits:Object.freeze({maxRequests:64,maxConcurrency:4,timeoutMS:25000,maxPayloadBytes:2000000}),
      library(service,input){return __callAsync('libraryAsync',service,input);},
      fetchJSON(url,options){return __callAsync('fetchAsync',url,options);}
    });
    """)
  if let error=exception() { throw MTVError.message(error) }
  return {
  let reader=AsyncPluginReplies(); reader.start(); defer { reader.stop() }
  context.evaluateScript("""
    Promise.resolve().then(()=>plugin.handle(__request.action,__request.input||{})).then(value=>{
      if(__pendingRPC.size)throw Error('Host calls must complete before the handler returns');
      __finishAsync(JSON.stringify(value)||'','');
    }).catch(error=>__finishAsync('',String(error)));
    """)
  let deadline=ProcessInfo.processInfo.systemUptime+24
  while completed==nil && rejected==nil {
    if let error=exception() { throw MTVError.message(error) }
    guard ProcessInfo.processInfo.systemUptime<deadline else { throw MTVError.message("Async plugin invocation exceeded its deadline") }
    if let frame=try reader.next() {
      context.setObject(frame,forKeyedSubscript:"__asyncIncoming" as NSString)
      context.evaluateScript("__deliverAsync(__asyncIncoming.id,__asyncIncoming.text)")
    } else if !RunLoop.current.run(mode:.default,before:Date().addingTimeInterval(0.005)) {
      Thread.sleep(forTimeInterval:0.001)
    }
  }
  if let error=rejected { throw MTVError.message(error) }
  if let error=exception() { throw MTVError.message(error) }
  guard let completed else { throw MTVError.message("Async plugin returned no result") }
  return completed
  }
}

import Foundation
import MTVCore

/// Diagnostic-only bounded range read. Counts Data callbacks without retaining
/// the body or iterating over individual bytes. No redirects or URL logging.
final class OriginTransferRead: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let queue=DispatchQueue(label:"mactv.quark.origin-transfer")
  private let request:URLRequest
  private let range:HTTPByteRange
  private let direct:Bool
  private var session:URLSession?
  private var continuation:CheckedContinuation<[String:Any],Never>?
  private var closed=false, received=0, status=0
  private var expected:Int?
  private var sourceLength:Int64=0
  private var prefix=Data()
  private var started=0.0, firstByteMS:Double?
  private var transactions:[[String:Any]]=[]
  init(request:URLRequest,range:HTTPByteRange,direct:Bool) {
    self.request=request; self.range=range; self.direct=direct
  }
  func run() async -> [String:Any] {
    await withTaskCancellationHandler(operation:{
      await withCheckedContinuation { continuation in queue.async { [self] in
        guard !closed else { continuation.resume(returning:["errorCode":URLError.cancelled.rawValue]); return }
        self.continuation=continuation; started=ProcessInfo.processInfo.systemUptime
        let config=URLSessionConfiguration.ephemeral
        config.httpCookieStorage=nil; config.urlCredentialStorage=nil; config.urlCache=nil; config.httpShouldSetCookies=false
        config.timeoutIntervalForRequest=12; config.timeoutIntervalForResource=30
        if direct { config.connectionProxyDictionary=[:] }
        let operations=OperationQueue(); operations.maxConcurrentOperationCount=1; operations.underlyingQueue=queue
        let session=URLSession(configuration:config,delegate:self,delegateQueue:operations)
        self.session=session; session.dataTask(with:request).resume()
      } }
    },onCancel:{ [self] in queue.async { [self] in finish(error:URLError(.cancelled)) } })
  }
  private func finish(error:Error?) {
    guard !closed else { return }; closed=true
    let elapsed=max(0.000001,ProcessInfo.processInfo.systemUptime-started)
    var result:[String:Any]=["http":status,"bytes":received,"complete":error==nil && received==expected,
      "firstByteMS":firstByteMS ?? -1,"elapsedMS":elapsed*1000,"bytesPerSecond":Double(received)/elapsed,
      "matroskaHeader":ContainerInspection.matroskaHeader(prefix),"observer":"URLSession.DataDelegate;bounded-counter",
      "transactions":transactions]
    if range.offset==0, sourceLength>0, let layout=MatroskaLayout.inspect(prefix,fileLength:UInt64(sourceLength)),
      let data=try? JSONEncoder().encode(layout), let object=try? JSONSerialization.jsonObject(with:data) { result["layout"]=object }
    if let element=MatroskaLayout.elementHeader(prefix,offset:UInt64(range.offset)),
      let data=try? JSONEncoder().encode(element), let object=try? JSONSerialization.jsonObject(with:data) { result["elementHeader"]=object }
    if let error { result["errorDomain"]=(error as NSError).domain; result["errorCode"]=(error as NSError).code }
    let continuation=self.continuation; self.continuation=nil
    session?.invalidateAndCancel(); session=nil
    continuation?.resume(returning:result)
  }
  func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,
    completionHandler:@escaping (URLSession.ResponseDisposition)->Void) {
    guard !closed else { completionHandler(.cancel); return }
    do {
      guard let http=response as? HTTPURLResponse, response.url?.host==request.url?.host else { throw URLError(.badServerResponse) }
      status=http.statusCode
      let info=try HTTPRangeResponse(status:http.statusCode,contentRange:http.value(forHTTPHeaderField:"Content-Range"),
        contentLength:http.value(forHTTPHeaderField:"Content-Length"),encoding:http.value(forHTTPHeaderField:"Content-Encoding"),requested:range)
      expected=info.count; sourceLength=info.totalLength; completionHandler(.allow)
    } catch { completionHandler(.cancel); finish(error:error) }
  }
  func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
    guard !closed, let expected else { return }
    guard data.count<=expected-received else { finish(error:URLError(.dataLengthExceedsMaximum)); return }
    if firstByteMS==nil { firstByteMS=(ProcessInfo.processInfo.systemUptime-started)*1000 }
    if prefix.count<4096 { prefix.append(data.prefix(4096-prefix.count)) }
    received += data.count
  }
  func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
    finish(error:error ?? (received==expected ? nil:URLError(.badServerResponse)))
  }
  func urlSession(_ session:URLSession,task:URLSessionTask,didFinishCollecting metrics:URLSessionTaskMetrics) {
    transactions=metrics.transactionMetrics.prefix(4).map { value in
      var result:[String:Any]=["proxyConnection":value.isProxyConnection,"protocol":value.networkProtocolName ?? "unknown",
        "remoteAddress":value.remoteAddress ?? "unknown"]
      if let start=value.fetchStartDate, let end=value.responseEndDate { result["fetchMS"]=end.timeIntervalSince(start)*1000 }
      return result
    }
  }
  func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,
    newRequest request:URLRequest,completionHandler:@escaping (URLRequest?)->Void) { completionHandler(nil) }
}

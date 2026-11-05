import AVFoundation
import Foundation
import MTVCore
import UniformTypeIdentifiers

struct RemoteResponseObservation: Codable, Sendable {
  var role = ""
  let host: String
  let offset: Int64
  let count: Int
  let status: Int
  let totalLength: Int64
  let mime: String
  let etag: String?
  let modified: String?
  let date: String?
  let ifRange: String?
}

/// Owns the public AVFoundation resource delegate for exactly one media URL.
final class RemoteHeaderStream: @unchecked Sendable {
  let asset: AVURLAsset
  private let loader: HeaderResourceLoader
  init(_ request: RemotePlaybackRequest) throws {
    guard request.url.pathExtension.lowercased() != "m3u8" else {
      throw MTVError.message("带请求头的 HLS 仍待适配；当前支持分段读取 MP4 / MOV")
    }
    let virtual = URL(string: "mtv-media://" + UUID().uuidString.lowercased() + "/movie.mp4")!
    loader = HeaderResourceLoader(request: request, virtualURL: virtual)
    asset = AVURLAsset(url: virtual, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
    asset.resourceLoader.setDelegate(loader, queue: loader.queue)
  }
  func cancel() { asset.cancelLoading(); loader.cancel() }
  func failureMessage() async -> String? { await loader.failureMessage() }
  func observations() async -> [RemoteResponseObservation] { await loader.observations() }
  func statistics() async -> [String: Int] { await loader.statistics() }
  deinit { loader.cancel() }
}

// All mutable state and both sets of delegate callbacks use the same serial queue.
private final class HeaderResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
  let queue = DispatchQueue(label: "local.mtv.preview.media-range")
  private let policy: RemotePlaybackRequest
  private let virtualURL: URL
  private var jobs: [ObjectIdentifier: Job] = [:]
  private var tasks: [Int: Job] = [:]
  private var closed = false
  private var length: Int64?
  private var type: String?
  private var version = HTTPResourceVersion()
  private var failure: String?
  private var responseObservations: [RemoteResponseObservation] = []
  private var requestCount = 0, receivedBytes = 0, completedRanges = 0
  private var deliveredBytes = 0, progressiveDeliveries = 0
  private let created = ProcessInfo.processInfo.systemUptime
  private var firstHeadersMS: Int?, firstBytesMS: Int?, firstDeliveryMS: Int?
  private let pooled = !(CommandLine.arguments.contains("--ui-smoke")
    && (CommandLine.arguments.contains("--playback-benchmark-only") || CommandLine.arguments.contains("--remote-header-only"))
    && CommandLine.arguments.contains("--test-isolated-header-session"))
  private var rangeTimings: [RangeTiming] = []
  private final class RangeTiming {
    let started = ProcessInfo.processInfo.systemUptime
    let offset: Int64, count: Int
    var headers: Int?, bytes: Int?, delivery: Int?, ended: Int?
    init(_ range: HTTPByteRange) { offset=range.offset; count=range.count }
    func elapsed() -> Int { Int((ProcessInfo.processInfo.systemUptime-started)*1000) }
  }
  private let progressive = CommandLine.arguments.contains("--ui-smoke")
    && CommandLine.arguments.contains("--test-progressive-header-ranges")
    && (CommandLine.arguments.contains("--playback-benchmark-only") || CommandLine.arguments.contains("--remote-header-only"))
  private let chunkBytes: Int = {
    let args = CommandLine.arguments
    guard args.contains("--ui-smoke"), args.contains("--playback-benchmark-only"),
      let index = args.firstIndex(of: "--benchmark-range-bytes"), index + 1 < args.count,
      let bytes = Int(args[index + 1]), [65536, 131072, 262144, 1048576].contains(bytes) else { return 1048576 }
    return bytes
  }()
  private lazy var session: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil; configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false; configuration.urlCredentialStorage = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 30
    configuration.httpMaximumConnectionsPerHost = 4
    let delegate = HeaderSessionDelegate(owner: self)
    let operations = OperationQueue(); operations.maxConcurrentOperationCount = 1; operations.underlyingQueue = queue
    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: operations)
  }()
  private final class Job {
    let request: AVAssetResourceLoadingRequest
    var offset: Int64
    let end: Int64?
    var range: HTTPByteRange?
    var response: HTTPRangeResponse?
    var responseType: String?
    var responseVersion = HTTPResourceVersion()
    var sentIfRange: String?
    var task: URLSessionDataTask?
    var body = Data()
    var received = 0
    var redirects = 0
    var timing: RangeTiming?
    init(_ request: AVAssetResourceLoadingRequest) throws {
      self.request = request
      if let data = request.dataRequest {
        guard data.requestedOffset >= 0, data.requestedLength >= 0 else { throw MTVError.message("无效的媒体读取请求") }
        offset = max(data.requestedOffset, data.currentOffset)
        if data.requestsAllDataToEndOfResource { end = nil }
        else {
          let sum = data.requestedOffset.addingReportingOverflow(Int64(data.requestedLength))
          guard !sum.overflow else { throw MTVError.message("媒体读取范围过大") }
          end = sum.partialValue
        }
      } else { offset = 0; end = nil }
    }
  }
  init(request: RemotePlaybackRequest, virtualURL: URL) { policy = request; self.virtualURL = virtualURL }
  func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
    guard request.request.url == virtualURL else { return false }
    do {
      guard !closed, jobs.count < 8 else { throw MTVError.message("媒体读取已结束或并发请求过多") }
      let job = try Job(request)
      jobs[ObjectIdentifier(request)] = job
      next(job)
    } catch { if !request.isCancelled && !request.isFinished { request.finishLoading(with: error) } }
    return true
  }
  func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel request: AVAssetResourceLoadingRequest) {
    if let job = jobs[ObjectIdentifier(request)] { finish(job, error: URLError(.cancelled)) }
  }
  func cancel() {
    queue.async { [self] in
      guard !closed else { return }
      closed = true
      for job in Array(jobs.values) { finish(job, error: URLError(.cancelled)) }
      if !pooled { session.invalidateAndCancel() }
    }
  }
  func failureMessage() async -> String? {
    await withCheckedContinuation { continuation in queue.async { [self] in continuation.resume(returning: failure) } }
  }
  func observations() async -> [RemoteResponseObservation] {
    await withCheckedContinuation { continuation in queue.async { [self] in
      continuation.resume(returning: responseObservations)
    } }
  }
  func statistics() async -> [String: Int] {
    await withCheckedContinuation { continuation in queue.async { [self] in
      var values = ["requests": requestCount, "receivedBytes": receivedBytes,
        "completedRanges": completedRanges, "chunkBytes": chunkBytes,
        "deliveredBytes":deliveredBytes,"progressiveDeliveries":progressiveDeliveries,
        "progressiveDelivery":progressive ? 1 : 0,"pooledTransport":pooled ? 1 : 0,"activeJobs":jobs.count]
      if let firstHeadersMS { values["firstHeadersMS"] = firstHeadersMS }
      if let firstBytesMS { values["firstBytesMS"] = firstBytesMS }
      if let firstDeliveryMS { values["firstDeliveryMS"] = firstDeliveryMS }
      for (index, timing) in rangeTimings.enumerated() {
        values["transfer.\(index).offset"] = Int(timing.offset)
        values["transfer.\(index).count"] = timing.count
        if let time=timing.headers { values["transfer.\(index).headersMS"] = time }
        if let time=timing.bytes { values["transfer.\(index).firstBytesMS"] = time }
        if let time=timing.delivery { values["transfer.\(index).firstDeliveryMS"] = time }
        if let time=timing.ended { values["transfer.\(index).endedMS"] = time }
      }
      for (index, observation) in responseObservations.enumerated() {
        values["range.\(index).offset"] = Int(observation.offset)
        values["range.\(index).count"] = observation.count
      }
      continuation.resume(returning: values)
    } }
  }
  private func next(_ job: Job) {
    guard !closed, jobs[ObjectIdentifier(job.request)] === job else { return }
    if job.request.isCancelled { finish(job, error: URLError(.cancelled)); return }
    if job.request.dataRequest != nil, let end = job.end, job.offset >= end,
      length != nil || job.request.contentInformationRequest == nil {
      finish(job); return
    }
    if let length, job.offset >= length { finish(job); return }
    do {
      let remaining = job.request.dataRequest == nil ? 2 : min(
        Int64(chunkBytes), min(job.end.map { max(1, $0 - job.offset) } ?? Int64.max,
          length.map { $0 - job.offset } ?? Int64.max))
      let range = try HTTPByteRange(offset: job.offset, count: Int(remaining))
      job.range = range; job.body = Data(); job.received = 0; job.response = nil; job.redirects = 0
      job.sentIfRange = version.ifRangeValue
      let request = try makeRequest(url: policy.url, range: range, ifRange: job.sentIfRange)
      let task = pooled ? HeaderSharedTransport.shared.task(request, owner:self) : session.dataTask(with:request)
      if CommandLine.arguments.contains("--ui-smoke"), rangeTimings.count < 32 {
        let timing=RangeTiming(range);rangeTimings.append(timing);job.timing=timing
      } else { job.timing=nil }
      requestCount += 1
      job.task = task; tasks[task.taskIdentifier] = job; task.resume()
    } catch { finish(job, error: error) }
  }
  private func makeRequest(url: URL, range: HTTPByteRange, ifRange: String?) throws -> URLRequest {
    var result = try policy.nativeRequest(for: url)
    result.httpMethod = "GET"
    for (key, value) in policy.headers { result.setValue(value, forHTTPHeaderField: key) }
    result.setValue(range.header, forHTTPHeaderField: "Range")
    result.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    if let ifRange { result.setValue(ifRange, forHTTPHeaderField: "If-Range") }
    return result
  }
  fileprivate func redirect(_ task: URLSessionTask, to request: URLRequest, completion: @escaping (URLRequest?) -> Void) {
    guard let job = tasks[task.taskIdentifier] else { completion(nil); return }
    guard let url = request.url, policy.permits(url), job.redirects < 3, let range = job.range else {
      failure = failure ?? "媒体跳转超出模块允许的域名或次数"; completion(nil); return
    }
    job.redirects += 1
    completion(try? makeRequest(url: url, range: range, ifRange: job.sentIfRange))
  }
  fileprivate func response(_ task: URLSessionDataTask, response: URLResponse, completion: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard let job = tasks[task.taskIdentifier], let range = job.range else { completion(.cancel); return }
    do {
      guard let http = response as? HTTPURLResponse, let url = http.url, policy.permits(url) else {
        throw MTVError.message("媒体响应来源不在允许范围")
      }
      let info = try HTTPRangeResponse(status: http.statusCode,
        contentRange: http.value(forHTTPHeaderField: "Content-Range"),
        contentLength: http.value(forHTTPHeaderField: "Content-Length"),
        encoding: http.value(forHTTPHeaderField: "Content-Encoding"), requested: range)
      if CommandLine.arguments.contains("--ui-smoke"), responseObservations.count < 32 {
        responseObservations.append(RemoteResponseObservation(host: url.host ?? "", offset: range.offset,
          count: range.count, status: http.statusCode, totalLength: info.totalLength, mime: http.mimeType ?? "",
          etag: http.value(forHTTPHeaderField: "ETag").map { String($0.prefix(256)) },
          modified: http.value(forHTTPHeaderField: "Last-Modified"), date: http.value(forHTTPHeaderField: "Date"),
          ifRange: job.sentIfRange.map { String($0.prefix(256)) }))
      }
      let mime = (http.mimeType ?? "").lowercased()
      let contentType: String
      switch mime {
      case "" where job.sentIfRange != nil && type != nil: contentType = type!
      case "video/mp4", "application/mp4": contentType = UTType.mpeg4Movie.identifier
      case "audio/mp4": contentType = UTType.mpeg4Audio.identifier
      case "video/quicktime": contentType = UTType.quickTimeMovie.identifier
      case "application/octet-stream" where ["mp4", "m4v", "m4s", "mov"].contains(policy.url.pathExtension.lowercased()):
        contentType = policy.url.pathExtension.lowercased() == "mov" ? UTType.quickTimeMovie.identifier : UTType.mpeg4Movie.identifier
      default: throw MTVError.message("带请求头的媒体路径当前支持 MP4 / MOV；此响应格式尚未适配")
      }
      if let length, length != info.totalLength { throw MTVError.message("播放期间媒体长度已改变，请重新打开") }
      if let type, type != contentType { throw MTVError.message("播放期间媒体格式已改变") }
      let etag = http.value(forHTTPHeaderField: "ETag")
      let modified = http.value(forHTTPHeaderField: "Last-Modified")
      let incoming = HTTPResourceVersion(etag: etag, lastModified: modified, responseDate: http.value(forHTTPHeaderField: "Date"))
      if version.conflicts(with: incoming, confirmedIfRange: job.sentIfRange) { throw MTVError.message("播放期间媒体版本已改变，请重新打开") }
      job.response = info; job.responseType = contentType; job.responseVersion = incoming
      job.timing?.headers=job.timing?.elapsed()
      if firstHeadersMS == nil { firstHeadersMS = Int((ProcessInfo.processInfo.systemUptime-created)*1000) }
      // Establish identity before any bytes from concurrent responses reach AVFoundation.
      if progressive {
        length = info.totalLength; type = contentType; version = version.merging(incoming)
        if let metadata = job.request.contentInformationRequest {
          metadata.contentLength = info.totalLength; metadata.contentType = contentType
          metadata.isByteRangeAccessSupported = true
        }
      }
      completion(.allow)
    } catch { completion(.cancel); finish(job, error: error) }
  }
  fileprivate func data(_ task: URLSessionDataTask, data: Data) {
    guard let job = tasks[task.taskIdentifier], let info = job.response else { return }
    guard data.count <= info.count - job.received else {
      finish(job, error: MTVError.message("媒体响应超过声明的字节范围")); return
    }
    job.received += data.count; job.body.append(data)
    if job.timing?.bytes == nil { job.timing?.bytes=job.timing?.elapsed() }
    if firstBytesMS == nil { firstBytesMS = Int((ProcessInfo.processInfo.systemUptime-created)*1000) }
    receivedBytes += data.count
    if progressive, job.body.count >= 16384 || job.received == info.count { deliver(job) }
  }
  private func deliver(_ job: Job) {
    guard let info = job.response, jobs[ObjectIdentifier(job.request)] === job,
      !job.request.isCancelled, !job.request.isFinished, let data = job.request.dataRequest else { return }
    let count = job.end.map { Int(min(Int64(job.body.count), max(0, $0 - job.offset))) } ?? job.body.count
    if count > 0 {
      if job.timing?.delivery == nil { job.timing?.delivery=job.timing?.elapsed() }
      if firstDeliveryMS == nil { firstDeliveryMS = Int((ProcessInfo.processInfo.systemUptime-created)*1000) }
      data.respond(with: job.body.prefix(count))
      job.offset += Int64(count); deliveredBytes += count
      if job.received < info.count { progressiveDeliveries += 1 }
    }
    job.body = Data()
  }
  fileprivate func completed(_ task: URLSessionTask, error: Error?) {
    guard let job = tasks.removeValue(forKey: task.taskIdentifier) else { return }
    if pooled { HeaderSharedTransport.shared.unregister(task.taskIdentifier) }
    job.timing?.ended=job.timing?.elapsed()
    job.task = nil
    guard error == nil, let info = job.response, let contentType = job.responseType, job.received == info.count else {
      finish(job, error: MTVError.message("媒体分段读取失败或未完整返回")); return
    }
    // Another in-flight range may have completed after these response headers arrived.
    guard (length == nil || length == info.totalLength), (type == nil || type == contentType),
      !version.conflicts(with: job.responseVersion, confirmedIfRange: job.sentIfRange) else {
      finish(job, error: MTVError.message("并发媒体响应的版本或长度不一致，请重新打开")); return
    }
    length = info.totalLength; type = contentType
    completedRanges += 1
    version = version.merging(job.responseVersion)
    if let metadata = job.request.contentInformationRequest {
      metadata.contentLength = info.totalLength; metadata.contentType = contentType
      metadata.isByteRangeAccessSupported = true
    }
    if job.request.dataRequest != nil {
      deliver(job)
      next(job)
    } else { finish(job) }
  }
  private func finish(_ job: Job, error: Error? = nil) {
    guard jobs.removeValue(forKey: ObjectIdentifier(job.request)) != nil else { return }
    if let message = (error as? MTVError)?.errorDescription { failure = failure ?? message }
    if let task = job.task {
      tasks.removeValue(forKey: task.taskIdentifier)
      if pooled { HeaderSharedTransport.shared.unregister(task.taskIdentifier) }
      job.timing?.ended=job.timing?.elapsed()
      task.cancel()
    }
    guard !job.request.isCancelled, !job.request.isFinished else { return }
    if let error { job.request.finishLoading(with: error) } else { job.request.finishLoading() }
  }
}

/// Only connection lifetime is shared. Each task is routed weakly to its owning
/// loader, which owns headers, resource identity and cancellation.
private final class HeaderSharedTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  static let shared = HeaderSharedTransport()
  private final class WeakOwner { weak var value: HeaderResourceLoader?; init(_ value: HeaderResourceLoader) { self.value=value } }
  private let lock=NSLock()
  private var owners:[Int:WeakOwner]=[:]
  private lazy var session: URLSession = {
    let config=URLSessionConfiguration.ephemeral
    config.urlCache=nil;config.httpCookieStorage=nil;config.httpShouldSetCookies=false;config.urlCredentialStorage=nil
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    config.timeoutIntervalForRequest=15;config.timeoutIntervalForResource=30;config.httpMaximumConnectionsPerHost=4
    let operations=OperationQueue();operations.maxConcurrentOperationCount=1
    return URLSession(configuration:config,delegate:self,delegateQueue:operations)
  }()
  func task(_ request:URLRequest, owner:HeaderResourceLoader) -> URLSessionDataTask {
    lock.lock();defer { lock.unlock() }
    let task=session.dataTask(with:request);owners[task.taskIdentifier]=WeakOwner(owner);return task
  }
  func unregister(_ id:Int) { lock.lock();owners.removeValue(forKey:id);lock.unlock() }
  private func owner(_ id:Int, remove:Bool=false) -> HeaderResourceLoader? {
    lock.lock();defer { lock.unlock() }
    let result=owners[id]?.value;if remove { owners.removeValue(forKey:id) };return result
  }
  func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive response:URLResponse,completionHandler:@escaping(URLSession.ResponseDisposition)->Void) {
    guard let owner=owner(dataTask.taskIdentifier) else { completionHandler(.cancel);return }
    owner.queue.async { owner.response(dataTask,response:response,completion:completionHandler) }
  }
  func urlSession(_ session:URLSession,dataTask:URLSessionDataTask,didReceive data:Data) {
    guard let owner=owner(dataTask.taskIdentifier) else { return };owner.queue.async { owner.data(dataTask,data:data) }
  }
  func urlSession(_ session:URLSession,task:URLSessionTask,didCompleteWithError error:Error?) {
    guard let owner=owner(task.taskIdentifier,remove:true) else { return };owner.queue.async { owner.completed(task,error:error) }
  }
  func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void) {
    guard let owner=owner(task.taskIdentifier) else { completionHandler(nil);return }
    owner.queue.async { owner.redirect(task,to:request,completion:completionHandler) }
  }
  func urlSession(_ session:URLSession,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
    completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling:.cancelAuthenticationChallenge,nil)
  }
  func urlSession(_ session:URLSession,task:URLSessionTask,didReceive challenge:URLAuthenticationChallenge,completionHandler:@escaping(URLSession.AuthChallengeDisposition,URLCredential?)->Void) {
    completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling:.cancelAuthenticationChallenge,nil)
  }
}

/// URLSession owns this proxy, which never retains its stream owner.
private final class HeaderSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private weak var owner: HeaderResourceLoader?
  init(owner: HeaderResourceLoader) { self.owner = owner }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard let owner else { completionHandler(.cancel); return }
    owner.response(dataTask, response: response, completion: completionHandler)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { owner?.data(dataTask, data: data) }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) { owner?.completed(task, error: error) }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    guard let owner else { completionHandler(nil); return }
    owner.redirect(task, to: request, completion: completionHandler)
  }
  func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
      ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
      ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
  }
}

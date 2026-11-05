import Foundation
import MTVCore

struct RemoteRangeChunk: Sendable {
  let data: Data
  let totalLength: Int64
}

/// Shared bounded HTTPS transport for indexed fragments. No cookie or credential store.
final class RemoteRangeClient: NSObject, @unchecked Sendable {
  private let policy: RemotePlaybackRequest
  private let useSystemProxy: Bool
  private let queue = DispatchQueue(label: "local.mtv.preview.indexed-range")
  private var jobs: [Int: Job] = [:]
  private var closed = false
  private var length: Int64?
  private var version = HTTPResourceVersion()
  private var requests = 0
  private var received = 0
  private var prefix: RemoteRangeChunk?
  private var prefixHits = 0
  private let traceEnabled=CommandLine.arguments.contains("--ui-smoke") && CommandLine.arguments.contains("--playback-benchmark-only")
  private let began=ProcessInfo.processInfo.systemUptime
  private var trace: [[String:Double]]=[]
  func seedPrefix(_ chunk: RemoteRangeChunk) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in queue.async { [self] in
      if !closed, chunk.data.count <= 262144, length == chunk.totalLength { prefix = chunk }
      continuation.resume()
    } }
  }
  private func cachedPrefix(offset: Int64, count: Int) async throws -> RemoteRangeChunk? {
    try Task.checkCancellation()
    return try await withCheckedThrowingContinuation { continuation in queue.async { [self] in
      guard !closed else { continuation.resume(throwing: CancellationError()); return }
      guard let prefix, offset >= 0, offset < prefix.data.count else { continuation.resume(returning: nil); return }
      let start = Int(offset), end = min(prefix.data.count, start + count)
      prefixHits += 1
      continuation.resume(returning: RemoteRangeChunk(data: prefix.data.subdata(in: start..<end), totalLength: prefix.totalLength))
    } }
  }
  private static let systemTransport = Transport(useSystemProxy:true)
  private static let directTransport = Transport(useSystemProxy:false)
  private var transport: Transport { useSystemProxy ? Self.systemTransport:Self.directTransport }
  private final class Cancellation: @unchecked Sendable {
    let lock = NSLock(); var cancelled = false; var taskID: Int?
    func cancel() -> Int? { lock.lock(); defer { lock.unlock() }; cancelled = true; return taskID }
    func register(_ id: Int) -> Bool { lock.lock(); defer { lock.unlock() }; taskID = id; return !cancelled }
  }
  private final class Job {
    let started=ProcessInfo.processInfo.systemUptime
    var firstByte: Double?
    let task: URLSessionDataTask
    let range: HTTPByteRange
    let condition: String?
    let continuation: CheckedContinuation<RemoteRangeChunk, Error>
    var info: HTTPRangeResponse?
    var version = HTTPResourceVersion()
    var data = Data()
    var redirects = 0
    let progress: (@Sendable (Data) -> Void)?
    var progressSent = 0
    init(task: URLSessionDataTask, range: HTTPByteRange, condition: String?, continuation: CheckedContinuation<RemoteRangeChunk, Error>,
      progress: (@Sendable (Data) -> Void)?) {
      self.task = task; self.range = range; self.condition = condition; self.continuation = continuation
      self.progress = progress
    }
  }
  init(_ policy: RemotePlaybackRequest, useSystemProxy: Bool = true) { self.policy = policy; self.useSystemProxy = useSystemProxy }
  func stream(offset: Int64, count: Int) -> OrderedRangePump.Read {
    // HTTPByteRange caps each streaming producer at 10 MiB. Coalescing below
    // bounds both byte storage and the number of queued Data objects.
    let stream = AsyncThrowingStream<Data, Error>.makeStream()
    let output = stream.continuation
    let producer = Task { [self] in
      do {
        _ = try await fetch(offset: offset, count: count, progress: { output.yield($0) })
        output.finish()
      } catch { output.finish(throwing: error) }
    }
    output.onTermination = { @Sendable reason in if case .cancelled = reason { producer.cancel() } }
    return OrderedRangePump.Read(chunks: stream.stream, cancel: { producer.cancel() })
  }
  func fetch(offset: Int64, count: Int, progress: (@Sendable (Data) -> Void)? = nil) async throws -> RemoteRangeChunk {
    guard policy.permits(policy.url) else { throw MTVError.message("媒体会话已失效或超出授权范围") }
    let range = try HTTPByteRange(offset: offset, count: count, maximumCount: progress == nil ? 1_048_576 : HTTPByteRange.maximumStreamingCount)
    if let cached = try await cachedPrefix(offset: offset, count: count) {
      try Task.checkCancellation()
      progress?(cached.data)
      if cached.data.count == count { return cached }
      let tail = try await fetch(offset: offset + Int64(cached.data.count), count: count - cached.data.count, progress: progress)
      guard tail.totalLength == cached.totalLength else { throw MTVError.message("缓存与远端媒体长度不一致") }
      try Task.checkCancellation()
      return RemoteRangeChunk(data: cached.data + tail.data, totalLength: tail.totalLength)
    }
    let cancellation = Cancellation()
    return try await withTaskCancellationHandler(operation: {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { continuation in
        queue.async { [self] in
          guard !closed, jobs.count < 8 else { continuation.resume(throwing: MTVError.message("分片读取已关闭或请求过多")); return }
          let condition = version.ifRangeValue
          let nativeRequest: URLRequest
          do { nativeRequest = try request(policy.url, range: range, condition: condition) }
          catch { continuation.resume(throwing: error); return }
          let task = transport.task(nativeRequest,owner:self)
          guard cancellation.register(task.taskIdentifier) else {
            transport.unregister(task.taskIdentifier); task.cancel(); continuation.resume(throwing: CancellationError()); return
          }
          jobs[task.taskIdentifier] = Job(task: task, range: range, condition: condition, continuation: continuation, progress: progress)
          requests += 1; task.resume()
        }
      }
    }, onCancel: { [self] in
      if let id = cancellation.cancel() { queue.async { [self] in finish(id, error: CancellationError()) } }
    })
  }
  func cancel() {
    queue.async { [self] in
      guard !closed else { return }; closed = true; prefix = nil
      for id in Array(jobs.keys) { finish(id, error: CancellationError()) }
    }
  }
  func statistics() async -> (requests: Int, received: Int, prefixHits: Int) {
    await withCheckedContinuation { continuation in queue.async { [self] in continuation.resume(returning: (requests, received, prefixHits)) } }
  }
  func benchmarkTrace() async -> [[String:Double]] {
    await withCheckedContinuation { continuation in queue.async { [self] in continuation.resume(returning:trace) } }
  }
  private func record(_ job: Job, success: Bool) {
    guard traceEnabled, trace.count<256 else { return }
    let now=ProcessInfo.processInfo.systemUptime
    trace.append(["offset":Double(job.range.offset),"count":Double(job.range.count),"received":Double(job.data.count),"startMS":(job.started-began)*1000,"durationMS":(now-job.started)*1000,"firstByteMS":job.firstByte.map{($0-job.started)*1000} ?? -1,"success":success ? 1:0])
  }
  private func request(_ url: URL, range: HTTPByteRange, condition: String?) throws -> URLRequest {
    var request = try policy.nativeRequest(for: url)
    for (name, value) in policy.headers { request.setValue(value, forHTTPHeaderField: name) }
    request.setValue(range.header, forHTTPHeaderField: "Range")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    if let condition { request.setValue(condition, forHTTPHeaderField: "If-Range") }
    return request
  }
  private func response(_ task: URLSessionDataTask, response: URLResponse, completion: @escaping (URLSession.ResponseDisposition) -> Void) {
    guard let job = jobs[task.taskIdentifier] else { completion(.cancel); return }
    do {
      guard let response = response as? HTTPURLResponse, let url = response.url, policy.permits(url) else { throw MTVError.message("分片响应域名越界") }
      let info = try HTTPRangeResponse(status: response.statusCode, contentRange: response.value(forHTTPHeaderField: "Content-Range"),
        contentLength: response.value(forHTTPHeaderField: "Content-Length"), encoding: response.value(forHTTPHeaderField: "Content-Encoding"), requested: job.range)
      let incoming = HTTPResourceVersion(etag: response.value(forHTTPHeaderField: "ETag"), lastModified: response.value(forHTTPHeaderField: "Last-Modified"), responseDate: response.value(forHTTPHeaderField: "Date"))
      guard (length == nil || length == info.totalLength), !version.conflicts(with: incoming, confirmedIfRange: job.condition) else { throw MTVError.message("分片资源身份已改变") }
      job.info = info; job.version = incoming; completion(.allow)
    } catch { completion(.cancel); finish(task.taskIdentifier, error: error) }
  }
  private func data(_ task: URLSessionDataTask, data: Data) {
    guard let job = jobs[task.taskIdentifier], let info = job.info else { return }
    if job.firstByte==nil { job.firstByte=ProcessInfo.processInfo.systemUptime }
    guard data.count <= info.count - job.data.count else { finish(task.taskIdentifier, error: MTVError.message("分片超过声明长度")); return }
    job.data.append(data); received += data.count
    if let progress = job.progress, job.data.count - job.progressSent >= 16_384 {
      progress(job.data.subdata(in: job.progressSent..<job.data.count)); job.progressSent = job.data.count
    }
  }
  private func complete(_ task: URLSessionTask, error: Error?) {
    guard let job = jobs[task.taskIdentifier] else { return }
    guard error == nil, let info = job.info, job.data.count == info.count,
      (length == nil || length == info.totalLength), !version.conflicts(with: job.version, confirmedIfRange: job.condition) else {
      finish(task.taskIdentifier, error: MTVError.message("分片读取未完成或资源已改变")); return
    }
    length = info.totalLength; version = version.merging(job.version)
    if let progress = job.progress, job.progressSent < job.data.count {
      progress(job.data.subdata(in: job.progressSent..<job.data.count)); job.progressSent = job.data.count
    }
    record(job,success:true)
    jobs.removeValue(forKey: task.taskIdentifier)
    transport.unregister(task.taskIdentifier)
    job.continuation.resume(returning: RemoteRangeChunk(data: job.data, totalLength: info.totalLength))
  }
  private func finish(_ id: Int, error: Error) {
    guard let job = jobs.removeValue(forKey: id) else { return }
    record(job,success:false)
    prefix = nil
    transport.unregister(id)
    job.task.cancel(); job.continuation.resume(throwing: error)
  }
  /// Connections outlive one playback. Request routing, resource versions and
  /// credentials remain owned by each client; the session stores no credentials.
  private final class Transport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class WeakOwner { weak var value:RemoteRangeClient?; init(_ value:RemoteRangeClient) { self.value=value } }
    private let lock=NSLock()
    private let useSystemProxy:Bool
    private var owners:[Int:WeakOwner]=[:]
    init(useSystemProxy:Bool) { self.useSystemProxy=useSystemProxy }
    private lazy var session:URLSession = {
      let configuration=URLSessionConfiguration.ephemeral
      configuration.urlCache=nil; configuration.httpCookieStorage=nil; configuration.httpShouldSetCookies=false
      configuration.urlCredentialStorage=nil; configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
      if !useSystemProxy { configuration.connectionProxyDictionary=[:] }
      configuration.timeoutIntervalForRequest=12; configuration.timeoutIntervalForResource=20
      let operations=OperationQueue(); operations.maxConcurrentOperationCount=1
      return URLSession(configuration:configuration,delegate:self,delegateQueue:operations)
    }()
    func task(_ request:URLRequest,owner:RemoteRangeClient) -> URLSessionDataTask {
      lock.lock(); defer { lock.unlock() }
      let task=session.dataTask(with:request)
      owners[task.taskIdentifier]=WeakOwner(owner)
      return task
    }
    func unregister(_ id:Int) { lock.lock(); owners.removeValue(forKey:id); lock.unlock() }
    private func owner(_ id:Int,remove:Bool=false) -> RemoteRangeClient? {
      lock.lock(); defer { lock.unlock() }
      let owner=owners[id]?.value
      if remove { owners.removeValue(forKey:id) }
      return owner
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
      guard let owner=owner(dataTask.taskIdentifier) else { completionHandler(.cancel); return }
      owner.queue.async { owner.response(dataTask,response:response,completion:completionHandler) }
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
      guard let owner=owner(dataTask.taskIdentifier) else { return }
      owner.queue.async { owner.data(dataTask,data:data) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
      guard let owner=owner(task.taskIdentifier,remove:true) else { return }
      owner.queue.async { owner.complete(task,error:error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
      guard let owner=owner(task.taskIdentifier) else { completionHandler(nil); return }
      owner.queue.async {
        guard let job=owner.jobs[task.taskIdentifier], let url=request.url, owner.policy.permits(url), job.redirects<3 else { completionHandler(nil); return }
        job.redirects += 1; completionHandler(try? owner.request(url,range:job.range,condition:job.condition))
      }
    }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
      completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
      completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
    }
  }
}

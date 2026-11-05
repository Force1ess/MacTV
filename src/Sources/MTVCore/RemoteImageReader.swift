import Foundation

public struct RemoteImageResponseError: LocalizedError, Sendable {
  public let status: Int
  public let oversized: Bool
  public let unsupportedType: Bool
  public var permitsOriginalPreview: Bool { [401,403,404,410].contains(status) }
  public var errorDescription: String? { "Cloud image response was rejected or exceeds its size limit." }
}

/// Bounded whole-image HTTPS transfer. Unlike media range transport this also
/// supports thumbnail CDNs that correctly return 200 without Range support.
public final class RemoteImageReader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private let policy: RemotePlaybackRequest
  private let maximum: Int
  private let configuration: URLSessionConfiguration
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Data,Error>?
  private var session: URLSession?
  private var buffer = Data()
  private var closed = false
  private var redirects = 0
  public init(request: RemotePlaybackRequest, maximum: Int) {
    policy = request; self.maximum = maximum; configuration = .ephemeral
  }
  init(request: RemotePlaybackRequest, maximum: Int, configuration: URLSessionConfiguration) {
    policy = request; self.maximum = maximum; self.configuration = configuration
  }
  public func read() async throws -> Data {
    guard (1...15_000_000).contains(maximum) else { throw MTVError.message("Invalid image transfer limit") }
    return try await withTaskCancellationHandler(operation: {
      try Task.checkCancellation()
      return try await withCheckedThrowingContinuation { value in
        lock.lock()
        guard !closed, continuation == nil else { lock.unlock(); value.resume(throwing:CancellationError()); return }
        continuation = value
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12; configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration:configuration,delegate:self,delegateQueue:nil)
        self.session = session
        do {
          let request = try policy.nativeRequest(for:policy.url)
          session.dataTask(with:request).resume(); lock.unlock()
        } catch { lock.unlock(); finish(.failure(error)) }
      }
    }, onCancel:{ self.finish(.failure(CancellationError())) })
  }
  private func finish(_ result: Result<Data,Error>) {
    lock.lock()
    guard !closed else { lock.unlock(); return }
    closed = true; let continuation = continuation, session = session
    self.continuation = nil; self.session = nil; buffer.removeAll()
    lock.unlock()
    session?.invalidateAndCancel(); continuation?.resume(with:result)
  }
  public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
    lock.lock(); redirects += 1; let allowed = redirects <= 3 && !closed; lock.unlock()
    guard allowed, let url = request.url, let native = try? policy.nativeRequest(for:url) else {
      completionHandler(nil); finish(.failure(MTVError.message("Cloud image redirect left its approved service."))); return
    }
    completionHandler(native)
  }
  public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    let type = response.mimeType?.lowercased() ?? ""
    guard let http = response as? HTTPURLResponse, http.statusCode == 200,
      response.expectedContentLength <= Int64(maximum),
      type.hasPrefix("image/") || type == "application/octet-stream" else {
      completionHandler(.cancel)
      finish(.failure(RemoteImageResponseError(status:(response as? HTTPURLResponse)?.statusCode ?? 0,
        oversized:response.expectedContentLength > Int64(maximum),
        unsupportedType: !(type.hasPrefix("image/") || type == "application/octet-stream"))))
      return
    }
    completionHandler(.allow)
  }
  public func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    guard !closed, buffer.count <= maximum - data.count else {
      lock.unlock(); finish(.failure(MTVError.message("Cloud image exceeds its size limit."))); return
    }
    buffer.append(data); lock.unlock()
  }
  public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error { finish(.failure(error)); return }
    lock.lock(); let data = buffer; lock.unlock()
    finish(data.isEmpty ? .failure(MTVError.message("Cloud image was empty.")) : .success(data))
  }
  public func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling:.cancelAuthenticationChallenge,nil)
  }
}

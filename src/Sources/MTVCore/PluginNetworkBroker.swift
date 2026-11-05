import Foundation

private final class PluginNetworkCancellation: @unchecked Sendable {
  private let lock = NSLock()
  private var cancelled = false
  private var work: [ObjectIdentifier: (URLSessionTask, @Sendable () -> Void)] = [:]
  private var testConfiguration: URLSessionConfiguration?
  func setTestConfiguration(_ configuration: URLSessionConfiguration) { lock.lock(); defer { lock.unlock() }; testConfiguration = configuration.copy() as? URLSessionConfiguration }
  func configuration() -> URLSessionConfiguration {
    lock.lock(); defer { lock.unlock() }; return (testConfiguration?.copy() as? URLSessionConfiguration) ?? .ephemeral
  }
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  func register(_ task: URLSessionTask, wake: @escaping @Sendable () -> Void) -> Bool {
    lock.lock(); defer { lock.unlock() }; guard !cancelled else { return false }; work[ObjectIdentifier(task)] = (task, wake); return true
  }
  func remove(_ task: URLSessionTask) { lock.lock(); defer { lock.unlock() }; work[ObjectIdentifier(task)] = nil }
  func cancel() {
    lock.lock(); cancelled = true; let values = Array(work.values); work.removeAll(); lock.unlock()
    for (task, wake) in values { task.cancel(); wake() }
  }
}

private final class BrokerFetcher: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  let cancellation: PluginNetworkCancellation
  let domains: [String]
  let sessionCredential: PluginSession?
  let capture: SessionCapture?
  var onAuthenticatedResponse: (@Sendable (HTTPURLResponse) -> Void)?
  let redactLoginResponse: Bool
  let authentication: PluginAuthentication?
  let requestReferer: String?
  let requestUserAgent: String?
  var buffer = Data()
  var responseError: String?
  let lock = NSLock()
  let finished = DispatchSemaphore(value: 0)
  var status = 0
  private var authenticatedHost: String?
  private var allowsRedirects = true
  init(
    domains: [String], session: PluginSession?, capture: SessionCapture?, redactLoginResponse: Bool,
    authentication: PluginAuthentication?, requestReferer: String? = nil, requestUserAgent: String? = nil, cancellation: PluginNetworkCancellation
  ) {
    self.cancellation = cancellation
    self.domains = domains
    sessionCredential = session
    self.capture = capture
    self.redactLoginResponse = redactLoginResponse
    self.authentication = authentication
    self.requestReferer = requestReferer
    self.requestUserAgent = requestUserAgent
    capture?.beginRequest()
  }
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard allowsRedirects, let url = request.url, NetworkPolicy.permits(url, domains: domains),
      authenticatedHost == nil || url.host?.lowercased() == authenticatedHost,
      authentication?.issuerDomains.contains(url.host?.lowercased() ?? "") != true,
      authentication?.issuerDomains.contains(response.url?.host?.lowercased() ?? "") != true
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock()
    defer { lock.unlock() }
    if buffer.count + data.count > 2_000_000 {
      responseError = "插件响应超过 2 MB 限制"
      dataTask.cancel()
    } else {
      buffer.append(data)
    }
  }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    lock.lock()
    status = (response as? HTTPURLResponse)?.statusCode ?? 0
    lock.unlock()
    if let response = response as? HTTPURLResponse {
      capture?.inspect(response: response)
      if authenticatedHost != nil { onAuthenticatedResponse?(response) }
    }
    completionHandler(.allow)
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock()
    if responseError == nil, let error { responseError = error.localizedDescription }
    lock.unlock()
    finished.signal()
  }
  func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    completionHandler(challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust ? .performDefaultHandling : .cancelAuthenticationChallenge, nil)
  }
  func fetch(_ address: String, authenticated: Bool, method: String = "GET", body: Data? = nil)
    -> String
  {
    guard !cancellation.isCancelled else { return Self.json(["error": "插件请求已取消"]) }
    guard let url = URL(string: address), NetworkPolicy.permits(url, domains: domains) else {
      return Self.json(["error": "拒绝请求：域名未授权或不是 HTTPS"])
    }
    let configuration = cancellation.configuration()
    configuration.httpCookieStorage = nil
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.timeoutIntervalForRequest = 8
    configuration.timeoutIntervalForResource = 10
    let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    var request = URLRequest(url: url)
    allowsRedirects = method == "GET"
    request.httpMethod = method
    request.httpBody = body
    if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
    if let requestReferer { request.setValue(requestReferer, forHTTPHeaderField: "Referer") }
    request.setValue(requestUserAgent ?? "Mozilla/5.0 MTVPrototype/0.1", forHTTPHeaderField: "User-Agent")
    request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
    if authenticated {
      guard let cookie = sessionCredential?.cookieHeader(for: url) else {
        return Self.json(["error": "此域名没有已授权的模块会话，请先登录"])
      }
      authenticatedHost = url.host?.lowercased()
      request.setValue(cookie, forHTTPHeaderField: "Cookie")
    }
    let task = session.dataTask(with: request)
    let signal = finished
    guard cancellation.register(task, wake: { signal.signal() }) else { task.cancel(); return Self.json(["error": "插件请求已取消"]) }
    defer { cancellation.remove(task) }
    task.resume()
    guard finished.wait(timeout: .now() + 11) == .success else {
      task.cancel()
      return Self.json(["error": "网络请求超时"])
    }
    guard !cancellation.isCancelled else { return Self.json(["error": "插件请求已取消"]) }
    lock.lock()
    defer { lock.unlock() }
    if let responseError { return Self.json(["error": responseError]) }
    if status != 200 {
      var result: [String: Any] = ["status": status, "body": ""]
      // Retain numeric provider diagnostics without passing arbitrary error
      // text, response bodies, redirect links or credential-shaped fields.
      if let object = try? JSONSerialization.jsonObject(with: buffer) as? [String: Any],
        let code = object["code"] as? NSNumber, CFGetTypeID(code) != CFBooleanGetTypeID(),
        code.doubleValue.isFinite, abs(code.doubleValue) < 1e12, code.doubleValue.rounded() == code.doubleValue {
        result["providerCode"] = code.int64Value
      }
      return Self.json(result)
    }
    capture?.confirm(body: buffer)
    if let authentication, let exchange = authentication.ticketExchange,
      let capture, url.path == exchange.sourcePath
    {
      do {
        if let redemption = try exchange.requestURL(
          body: buffer, source: url, authentication: authentication)
        {
          // This second request stays entirely in native code. In particular the
          // one-time ticket is never returned in the plugin's public payload.
          let redeemed = BrokerFetcher(
            domains: domains, session: nil, capture: capture,
            redactLoginResponse: true, authentication: authentication,
            requestReferer: requestReferer, requestUserAgent: requestUserAgent, cancellation: cancellation
          )
          .fetch(redemption.absoluteString, authenticated: false)
          guard let data = redeemed.data(using: .utf8),
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            result["error"] == nil, capture.value() != nil
          else { return Self.json(["error": "平台未确认票据兑换或未返回完整会话，未保存登录状态"]) }
        }
      } catch {
        return Self.json(["error": "无法安全兑换平台登录票据，未保存登录状态"])
      }
    }
    var body = String(data: buffer, encoding: .utf8) ?? ""
    if redactLoginResponse {
      // Login redirect URLs and refresh tokens can embed credentials. Only public
      // progress fields may cross back into JavaScript after session capture.
      guard let safe = try? LoginResponseSanitizer.publicPayload(buffer),
        var publicObject = try? JSONSerialization.jsonObject(with: safe) as? [String: Any]
      else {
        return Self.json(["error": "无法读取登录状态响应"])
      }
      publicObject["_mtvSessionCaptured"] = capture?.value() != nil
      guard let encoded = try? JSONSerialization.data(withJSONObject: publicObject),
        let text = String(data: encoded, encoding: .utf8)
      else {
        return Self.json(["error": "无法读取登录状态响应"])
      }
      body = text
    }
    return Self.json(["status": status, "body": body])
  }
  static func json(_ object: Any) -> String {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
      let value = String(data: data, encoding: .utf8)
    else { return "{}" }
    return value
  }
}

public final class PluginNetworkBroker: @unchecked Sendable {
  private let manifest: PluginManifest
  private let credential: PluginSession?
  private let credentialLock = NSLock()
  private var currentCredential: PluginSession?
  private let action: String
  private let sessionCapture: SessionCapture
  private let cancellation = PluginNetworkCancellation()
  public init(manifest: PluginManifest, action: String, credential: PluginSession?) throws {
    try manifest.validate()
    guard manifest.capabilities.contains(action) else { throw MTVError.message("插件未声明此操作能力") }
    if let credential { try credential.validate(for: manifest) }
    self.manifest = manifest; self.action = action; self.credential = credential; currentCredential = credential
    sessionCapture = SessionCapture(manifest: manifest)
  }
  private func credentialSnapshot() -> PluginSession? {
    credentialLock.lock(); defer { credentialLock.unlock() }; return currentCredential
  }
  public var refreshedSession: PluginSession? {
    guard let value = credentialSnapshot(), value.cookie != credential?.cookie || value.expiresAt != credential?.expiresAt else { return nil }
    return value
  }
  private func refresh(_ response: HTTPURLResponse, expected: PluginSession?) {
    guard let expected, let updated = expected.refreshingQuarkCookies(from: response) else { return }
    credentialLock.lock(); defer { credentialLock.unlock() }
    guard currentCredential?.cookie == expected.cookie else { return }
    currentCredential = updated
  }
  public var sessionAvailable: Bool { credential != nil }
  public func requestAsync(_ address: String, optionsJSON: String) async -> String {
    await withTaskCancellationHandler(operation: {
      await withCheckedContinuation { continuation in
        DispatchQueue.global(qos:.userInitiated).async { [self] in continuation.resume(returning:request(address,optionsJSON:optionsJSON)) }
      }
    },onCancel:{ self.cancel() })
  }
  func useConfigurationForTesting(_ configuration: URLSessionConfiguration) { cancellation.setTestConfiguration(configuration) }
  public func cancel() { cancellation.cancel() }
  public func capturedSession(result: Any) -> PluginSession? {
    guard action == "login", (result as? [String: Any])?["state"] as? String == "authorized" else { return nil }
    return sessionCapture.value()
  }
  public static func json(_ value: Any) -> String { BrokerFetcher.json(value) }
  public func request(_ address: String, optionsJSON: String) -> String {
    guard !cancellation.isCancelled, address.utf8.count <= 16_384, optionsJSON.utf8.count <= 131_072 else { return Self.json(["error": "代理请求已取消或超过大小限制"]) }
    guard let data = optionsJSON.data(using: .utf8),
      let options = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      Set(options.keys).isSubset(of: ["authenticated", "captureSession", "method", "body"])
    else {
      return BrokerFetcher.json(["error": "无效的网络请求选项"])
    }
    let shouldCapture = options["captureSession"] as? Bool == true
    guard !shouldCapture || action == "login" else {
      return BrokerFetcher.json(["error": "仅登录操作可以接收新会话"])
    }
    guard let url = URL(string: address) else { return BrokerFetcher.json(["error": "无效网络地址"]) }
    let method = options["method"] as? String ?? "GET"
    let requestBody: Data?
    if method == "POST" {
      guard manifest.postEndpoints?.contains(where: { $0.permits(url) }) == true,
        let body = options["body"] as? [String: Any], JSONSerialization.isValidJSONObject(body),
        let data = try? JSONSerialization.data(withJSONObject: body), data.count <= 64_000
      else { return BrokerFetcher.json(["error": "此 POST 端点未授权或请求体无效"]) }
      requestBody = data
    } else {
      guard method == "GET", options["body"] == nil else {
        return BrokerFetcher.json(["error": "仅支持声明的 POST 或无请求体的 GET"])
      }
      requestBody = nil
    }
    let authentication = manifest.authentication
    let host = url.host?.lowercased() ?? ""
    let isIssuer = authentication?.issuerDomains.contains(host) == true
    let isCredentialPath =
      isIssuer && authentication?.credentialPaths.contains(url.standardized.path) == true
    if isIssuer, authentication?.sessionDomains.contains(host) != true,
      !isCredentialPath, authentication?.challengePaths.contains(url.standardized.path) != true
    {
      return BrokerFetcher.json(["error": "登录域名只允许声明的授权端点"])
    }
    guard !shouldCapture || isCredentialPath else {
      return BrokerFetcher.json(["error": "此地址未声明为会话接收端点"])
    }
    let credential = credentialSnapshot()
    let fetcher = BrokerFetcher(
      domains: manifest.domains, session: credential,
      capture: action == "login" && isCredentialPath ? sessionCapture : nil,
      redactLoginResponse: isCredentialPath, authentication: authentication,
      requestReferer: manifest.requestReferer, requestUserAgent: manifest.requestUserAgent, cancellation: cancellation
    )
    fetcher.onAuthenticatedResponse = { [weak self] response in self?.refresh(response, expected: credential) }
    return fetcher.fetch(
      address, authenticated: options["authenticated"] as? Bool == true, method: method,
      body: requestBody)
  }
}


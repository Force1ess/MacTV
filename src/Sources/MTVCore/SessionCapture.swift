import Foundation

/// Pairs HTTPS response cookies with a separately verified server success code.
public final class SessionCapture: @unchecked Sendable {
  private let lock = NSLock()
  private var candidate: PluginSession?
  private var confirmed = false
  private var confirmationBooleanPath: [String]?
  private let manifest: PluginManifest
  public init(manifest: PluginManifest) { self.manifest = manifest }
  public func beginRequest() {
    lock.lock()
    candidate = nil
    confirmed = false
    confirmationBooleanPath = nil
    lock.unlock()
  }
  public func inspect(response: HTTPURLResponse) {
    guard response.statusCode == 200, let url = response.url,
      let authentication = manifest.authentication,
      NetworkPolicy.permits(url, domains: authentication.issuerDomains),
      authentication.credentialPaths.contains(url.standardized.path)
    else { return }
    let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
      if let key = pair.key as? String, let value = pair.value as? String { result[key] = value }
    }
    let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).filter { cookie in
      let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        .lowercased()
      return authentication.cookieNames.contains(cookie.name) && cookie.isSecure
        && cookie.path == "/"
        && (cookie.expiresDate.map { $0 > Date() } ?? true)
        && authentication.sessionDomains.allSatisfy { $0 == domain || $0.hasSuffix("." + domain) }
    }
    guard Set(authentication.requiredCookieNames).isSubset(of: Set(cookies.map(\.name))) else {
      return
    }
    let header = cookies.sorted { $0.name < $1.name }.map { "\($0.name)=\($0.value)" }.joined(
      separator: "; ")
    let session = PluginSession(
      pluginID: manifest.id, domains: authentication.sessionDomains,
      cookie: header,
      expiresAt: cookies.compactMap(\.expiresDate).map(\.timeIntervalSince1970).min())
    guard (try? session.validate(for: manifest)) != nil else { return }
    lock.lock()
    candidate = session
    confirmed = false
    if let exchange = authentication.ticketExchange,
      let endpoint = URL(string: exchange.endpoint), endpoint.host == url.host,
      endpoint.path == url.path
    {
      confirmationBooleanPath = exchange.confirmationBooleanPath
    } else {
      confirmationBooleanPath = nil
    }
    lock.unlock()
  }
  public func confirm(body: Data) {
    guard let authentication = manifest.authentication,
      let root = try? JSONSerialization.jsonObject(with: body)
    else { return }
    lock.lock()
    let booleanPath = confirmationBooleanPath
    lock.unlock()
    if let booleanPath {
      guard let value = PluginTicketExchange.value(root, path: booleanPath) as? NSNumber,
        CFGetTypeID(value) == CFBooleanGetTypeID(), value.boolValue
      else { return }
      lock.lock()
      confirmed = candidate != nil
      lock.unlock()
      return
    }
    var cursor: Any = root
    for component in authentication.successCodePath {
      guard let object = cursor as? [String: Any], let value = object[component] else { return }
      cursor = value
    }
    guard let number = cursor as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      number.doubleValue == Double(authentication.successCode)
    else { return }
    lock.lock()
    confirmed = candidate != nil
    lock.unlock()
  }
  public func value() -> PluginSession? {
    lock.lock()
    defer { lock.unlock() }
    return confirmed ? candidate : nil
  }
}

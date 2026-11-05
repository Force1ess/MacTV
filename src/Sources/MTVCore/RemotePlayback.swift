import Foundation

public struct RemotePlaybackRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
  public let url: URL
  public let headers: [String: String]
  public let domains: [String]
  private let fixtureOrigin: URL?
  private var nativeMediaSession: PluginSession? = nil
  private var approvedMediaHost: String? = nil
  private var quarkPlaybackServiceApproved = false
  public var requiresNativeLoader: Bool { !headers.isEmpty || nativeMediaSession != nil }
  public var carriesNativeSession: Bool { nativeMediaSession != nil }
  public var description: String { "RemotePlaybackRequest(host: \(url.host ?? "unknown"), nativeSession: \(carriesNativeSession))" }
  public var debugDescription: String { description }
  public var customMirror: Mirror { Mirror(self, children: ["host": url.host ?? "unknown", "nativeSession": String(carriesNativeSession)]) }
  /// Native-only authorization. The operator must have approved this exact
  /// first-party subdomain; script-provided headers remain credential-free.
  public func authorizingMediaSession(_ session: PluginSession, approvedHost: String, quarkPlaybackService: Bool = false) throws -> Self {
    guard fixtureOrigin == nil, approvedHost == approvedHost.lowercased(), approvedHost == url.host?.lowercased(),
      session.domains.contains(where: { approvedHost == $0 || approvedHost.hasSuffix("." + $0) }),
      !session.cookie.isEmpty, session.cookie.utf8.count <= 16000,
      session.cookie.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 }),
      session.expiresAt.map({ $0.isFinite && $0 > Date().timeIntervalSince1970 }) ?? true,
      NetworkPolicy.permitsPlayback(url, domains: domains)
    else { throw MTVError.message("媒体会话未获此精确主机的授权") }
    var copy = self; copy.nativeMediaSession = session; copy.approvedMediaHost = approvedHost
    if quarkPlaybackService {
      guard session.pluginID == "mtv.quark", FirstPartyMediaScope.isQuarkPlaybackHost(approvedHost) else { throw MTVError.message("Invalid native playback service scope") }
      copy.quarkPlaybackServiceApproved = true
    }
    return copy
  }
  public func nativeRequest(for candidate: URL) throws -> URLRequest {
    guard permits(candidate) else { throw MTVError.message("媒体请求越出已批准范围") }
    var request = URLRequest(url: candidate)
    request.httpShouldHandleCookies = false
    for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
    if let nativeMediaSession { request.setValue(nativeMediaSession.cookie, forHTTPHeaderField: "Cookie") }
    return request
  }
  public init(url: URL, domains: [String], headers: [String: String], referer: String?) throws {
    guard url.fragment == nil, NetworkPolicy.permitsPlayback(url, domains: domains) else {
      throw MTVError.message("播放地址不在模块声明的 HTTPS 域名范围")
    }
    self.url = url; self.domains = domains; fixtureOrigin = nil
    self.headers = try Self.checkedHeaders(headers, referer: referer)
  }
  private init(fixture: URL, headers: [String: String], referer: String?) throws {
    guard CommandLine.arguments.contains("--ui-smoke"), fixture.scheme == "http",
      fixture.host == "127.0.0.1", let port = fixture.port, (1024...65535).contains(port),
      fixture.user == nil, fixture.password == nil, fixture.fragment == nil,
      fixture.path.hasPrefix("/mtv-fixture/") else { throw MTVError.message("只允许显式界面测试的回环片源") }
    url = fixture; domains = []; fixtureOrigin = fixture
    self.headers = try Self.checkedHeaders(headers, referer: referer)
  }
  public static func testingLoopback(url: URL, headers: [String: String], referer: String?) throws -> Self {
    try Self(fixture: url, headers: headers, referer: referer)
  }
  public func permits(_ candidate: URL) -> Bool {
    guard candidate.fragment == nil else { return false }
    if let nativeMediaSession {
      let host = candidate.host?.lowercased() ?? ""
      guard (host == approvedMediaHost || (quarkPlaybackServiceApproved && FirstPartyMediaScope.isQuarkPlaybackHost(host))),
        nativeMediaSession.expiresAt.map({ $0 > Date().timeIntervalSince1970 }) ?? true else { return false }
    }
    if let fixtureOrigin {
      return candidate.scheme == "http" && candidate.host == "127.0.0.1"
        && candidate.port == fixtureOrigin.port && candidate.user == nil && candidate.password == nil
        && candidate.path.hasPrefix("/mtv-fixture/")
    }
    return NetworkPolicy.permitsPlayback(candidate, domains: domains)
  }
  private static func checkedHeaders(_ headers: [String: String], referer: String?) throws -> [String: String] {
    guard headers.count <= 2 else { throw MTVError.message("播放请求头超出允许范围") }
    var result: [String: String] = [:]
    for (key, value) in headers {
      let name = key.lowercased()
      guard ["user-agent", "referer"].contains(name), result[name] == nil,
        !value.isEmpty, value.utf8.count <= (name == "user-agent" ? 512 : 2048),
        value.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 127 })
      else { throw MTVError.message("播放仅允许无控制字符的 User-Agent 和已声明 Referer；不接受账号凭据") }
      if name == "referer" {
        guard let referer, value == referer, let url = URL(string: referer), url.scheme == "https",
          url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
          url.port == nil || url.port == 443 else { throw MTVError.message("播放 Referer 与模块声明不符") }
      }
      result[name] = value
    }
    return result
  }
}

public struct HTTPByteRange: Equatable, Sendable {
  public static let maximumStreamingCount = 10 * 1024 * 1024
  public let offset: Int64
  public let count: Int
  public init(offset: Int64, count: Int, maximumCount: Int = 1_048_576) throws {
    guard (1...Self.maximumStreamingCount).contains(maximumCount), offset >= 0, count > 0, count <= maximumCount,
      !offset.addingReportingOverflow(Int64(count - 1)).overflow
    else { throw MTVError.message("播放字节范围无效") }
    self.offset = offset; self.count = count
  }
  public var upperBound: Int64 { offset + Int64(count - 1) }
  public var header: String { "bytes=\(offset)-\(upperBound)" }
}

public struct HTTPResourceVersion: Equatable, Sendable {
  public let etag: String?
  public let lastModified: String?
  public let responseDate: String?
  public init(etag: String? = nil, lastModified: String? = nil, responseDate: String? = nil) {
    self.etag = etag; self.lastModified = lastModified; self.responseDate = responseDate
  }
  private static func date(_ value: String?) -> Date? {
    guard let value, value.utf8.count == 29 else { return nil }
    let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX")
    format.calendar = Calendar(identifier: .gregorian); format.timeZone = TimeZone(secondsFromGMT: 0)
    format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"; format.isLenient = false
    return format.date(from: value)
  }
  public var lastModifiedIsStrong: Bool {
    guard let modified = Self.date(lastModified), let sent = Self.date(responseDate) else { return false }
    return sent.timeIntervalSince(modified) >= 60
  }
  public var ifRangeValue: String? {
    guard let etag, etag.utf8.count <= 2048, etag.first == "\"", etag.last == "\"", etag.count >= 2,
      etag.dropFirst().dropLast().unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value < 127 && $0.value != 34 }) else { return nil }
    return etag
  }
  /// confirmedIfRange is only valid after a validated HTTP 206 response.
  public func conflicts(with other: Self, confirmedIfRange: String? = nil) -> Bool {
    if let expected = confirmedIfRange {
      if other.etag != nil && other.ifRangeValue != expected { return true }
      if let current = ifRangeValue { return current != expected }
      return false
    }
    if let tag = ifRangeValue, let incoming = other.ifRangeValue { return tag != incoming }
    if lastModifiedIsStrong, other.lastModifiedIsStrong,
      let old = Self.date(lastModified), let new = Self.date(other.lastModified) { return old != new }
    return false
  }
  public func merging(_ other: Self) -> Self {
    let upgradeDate = lastModified == other.lastModified && !lastModifiedIsStrong && other.lastModifiedIsStrong
    return Self(etag: etag ?? other.etag, lastModified: lastModified ?? other.lastModified,
      responseDate: lastModified == nil || upgradeDate ? other.responseDate : responseDate)
  }
}

public struct HTTPRangeResponse: Equatable, Sendable {
  public let totalLength: Int64
  public let count: Int
  public init(status: Int, contentRange: String?, contentLength: String?, encoding: String?, requested: HTTPByteRange) throws {
    guard status == 206 else { throw MTVError.message(L("媒体服务器返回 HTTP \(status)，未提供所需的分段响应")) }
    guard encoding == nil || encoding?.lowercased() == "identity",
      let contentRange, contentRange.lowercased().hasPrefix("bytes ") else {
      throw MTVError.message("媒体服务器没有提供有效的未压缩分段响应")
    }
    let parts = contentRange.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 2, let total = Int64(parts[1]), total > 0,
      parts[1].allSatisfy({ $0.isASCII && $0.isNumber }) else { throw MTVError.message("媒体长度无效") }
    let bounds = parts[0].split(separator: "-", omittingEmptySubsequences: false)
    guard bounds.count == 2, bounds.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }),
      let start = Int64(bounds[0]), let end = Int64(bounds[1]), start == requested.offset,
      end == min(requested.upperBound, total - 1), end >= start
    else { throw MTVError.message("媒体服务器返回的字节范围不符") }
    let length = Int(end - start + 1)
    if let contentLength {
      guard !contentLength.isEmpty, contentLength.allSatisfy({ $0.isASCII && $0.isNumber }),
        Int64(contentLength) == Int64(length) else { throw MTVError.message("媒体响应长度不符") }
    }
    totalLength = total; count = length
  }
}

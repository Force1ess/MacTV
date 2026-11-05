import Foundation

public struct ChromeBilibiliSessionImport: Decodable {
  let schema: Int
  let provider: String
  let cookies: [Cookie]
  struct Cookie: Decodable {
    let name: String, value: String, domain: String, path: String
    let hostOnly: Bool
    let expirationDate: Double?
  }
  public func session(now: Double = Date().timeIntervalSince1970) throws -> PluginSession {
    guard schema == 1, provider == "mtv.bilibili", (1...16).contains(cookies.count) else { throw MTVError.message("B站登录导入格式无效") }
    var selected: [String: String] = [:], expiries: [Double] = []
    for cookie in cookies {
      let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
      guard ["SESSDATA", "bili_jct", "DedeUserID", "DedeUserID__ckMd5"].contains(cookie.name),
        ["bilibili.com", "api.bilibili.com"].contains(domain), !cookie.hostOnly || domain == "api.bilibili.com",
        cookie.path == "/", !cookie.value.isEmpty, cookie.value.utf8.count <= 8192,
        cookie.value.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 && $0 != ";" }) else {
        throw MTVError.message("仅接受适用于B站API的登录Cookie")
      }
      if let expiry = cookie.expirationDate {
        guard expiry.isFinite, expiry > now else { throw MTVError.message("Chrome中的B站登录已过期") }
        expiries.append(expiry)
      }
      if let previous = selected[cookie.name], previous != cookie.value { throw MTVError.message("B站登录Cookie存在冲突，请在Chrome重新登录") }
      selected[cookie.name] = cookie.value
    }
    guard selected["SESSDATA"] != nil else { throw MTVError.message("这份Chrome资料没有B站登录，请先在Chrome登录哔哩哔哩") }
    let header = selected.keys.sorted().map { "\($0)=\(selected[$0]!)" }.joined(separator: "; ")
    guard header.utf8.count <= 16000 else { throw MTVError.message("B站登录超过导入上限") }
    return PluginSession(pluginID: "mtv.bilibili", domains: ["api.bilibili.com"], cookie: header, expiresAt: expiries.min())
  }
}

private final class BilibiliImportRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public enum BilibiliImportedSessionValidator {
  public static func accepts(_ data: Data) -> Bool {
    guard data.count <= 1_048_576,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["code"] as? Int == 0, let payload = object["data"] as? [String: Any],
      payload["isLogin"] as? Bool == true, let mid = payload["mid"] as? Int64, mid > 0 else { return false }
    return true
  }
  public static func verify(_ session: PluginSession) async throws -> PluginSession {
    let url = URL(string: "https://api.bilibili.com/x/web-interface/nav")!
    guard session.pluginID == "mtv.bilibili", let cookie = session.cookieHeader(for: url) else { throw MTVError.message("B站登录范围无效") }
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
    config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
    let client = URLSession(configuration: config, delegate: BilibiliImportRedirectGuard(), delegateQueue: nil)
    defer { client.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.setValue(cookie, forHTTPHeaderField: "Cookie")
    request.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    request.setValue("Mozilla/5.0 MTVPrototype/0.1", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await client.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200, accepts(data) else { throw MTVError.message("B站未接受此登录，请在Chrome重新登录后再导入") }
    return session
  }
}

public enum ChromePlatformSession {
  public static func decode(_ data: Data) throws -> PluginSession {
    struct Identity: Decodable { let provider: String }
    switch try JSONDecoder().decode(Identity.self, from: data).provider {
    case "mtv.quark": return try JSONDecoder().decode(ChromeQuarkSessionImport.self, from: data).session()
    case "mtv.bilibili": return try JSONDecoder().decode(ChromeBilibiliSessionImport.self, from: data).session()
    default: throw MTVError.message("不支持此平台的Chrome导入")
    }
  }
  public static func verify(_ session: PluginSession) async throws -> PluginSession {
    switch session.pluginID {
    case "mtv.quark": return try await QuarkImportedSessionValidator.verify(session)
    case "mtv.bilibili": return try await BilibiliImportedSessionValidator.verify(session)
    default: throw MTVError.message("不支持此平台的Chrome导入")
    }
  }
}

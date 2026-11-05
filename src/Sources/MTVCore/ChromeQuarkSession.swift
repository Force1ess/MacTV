import Foundation

public struct ChromeQuarkSessionImport: Decodable {
  public static let extensionID = "pmiigeddpdalgdnioaeabigmmddngfbj"
  public static let origin = "chrome-extension://" + extensionID + "/"
  public struct Cookie: Decodable {
    let name: String, value: String, domain: String, path: String
    let hostOnly: Bool
    let expirationDate: Double?
  }
  let schema: Int
  let provider: String
  let cookies: [Cookie]
  public func session(now: Double = Date().timeIntervalSince1970) throws -> PluginSession {
    guard schema == 1, provider == "mtv.quark", (1...16).contains(cookies.count) else { throw MTVError.message("Chrome会话导入格式无效") }
    let allowed = Set(["__pus", "__puus", "__kps", "__uid"])
    var selected: [String: String] = [:], expiries: [Double] = [], cookieExpiries: [String: Double] = [:]
    for cookie in cookies {
      let domain = cookie.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
      guard allowed.contains(cookie.name), ["quark.cn", "drive.quark.cn"].contains(domain),
        !cookie.hostOnly || domain == "drive.quark.cn", cookie.path == "/",
        !cookie.value.isEmpty, cookie.value.utf8.count <= 8192,
        cookie.value.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 && $0 != ";" }) else {
        throw MTVError.message("导入仅接受适用于夸克网盘的会话Cookie")
      }
      if let expiry = cookie.expirationDate {
        guard expiry.isFinite, expiry > now else { throw MTVError.message("Chrome中的夸克会话已过期") }
        expiries.append(expiry); cookieExpiries[cookie.name] = expiry
      }
      if let old = selected[cookie.name], old != cookie.value { throw MTVError.message("Chrome会话Cookie存在冲突，请重新登录夸克") }
      selected[cookie.name] = cookie.value
    }
    guard selected["__pus"] != nil || selected["__puus"] != nil else { throw MTVError.message("Chrome未返回完整夸克登录会话") }
    let header = selected.keys.sorted().map { "\($0)=\(selected[$0]!)" }.joined(separator: "; ")
    guard header.utf8.count <= 16000 else { throw MTVError.message("Chrome会话超过导入上限") }
    return PluginSession(pluginID: "mtv.quark", domains: ["drive.quark.cn"], cookie: header, expiresAt: expiries.min(), cookieExpiries: cookieExpiries)
  }
}

private final class QuarkImportRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

public enum QuarkImportedSessionValidator {
  /// Read-only, one-item directory request. Never forwards credentials on redirects.
  public static func verify(_ session: PluginSession) async throws -> PluginSession {
    let url = URL(string: "https://drive.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&pdir_fid=0&_page=1&_size=1&_fetch_total=0&_sort=file_type:asc,file_name:asc")!
    guard let cookie = session.cookieHeader(for: url) else { throw MTVError.message("夸克会话范围无效") }
    let config = URLSessionConfiguration.ephemeral
    config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
    config.timeoutIntervalForRequest = 10; config.timeoutIntervalForResource = 15
    let client = URLSession(configuration: config, delegate: QuarkImportRedirectGuard(), delegateQueue: nil)
    defer { client.invalidateAndCancel() }
    var request = URLRequest(url: url)
    request.setValue(cookie, forHTTPHeaderField: "Cookie")
    request.setValue("https://pan.quark.cn/", forHTTPHeaderField: "Referer")
    request.setValue("Mozilla/5.0 MTVPrototype/0.1", forHTTPHeaderField: "User-Agent")
    let (data, response) = try await client.data(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 1_048_576,
      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      object["code"] as? Int == 0, object["status"] as? Int == 200,
      let payload = object["data"] as? [String: Any], payload["list"] is [[String: Any]] else {
      throw MTVError.message("夸克未接受此会话，请在Chrome重新登录后导入")
    }
    guard let http = response as? HTTPURLResponse else { return session }
    return session.refreshingQuarkCookies(from: http) ?? session
  }
}

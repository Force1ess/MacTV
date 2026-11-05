import Foundation

extension PluginSession {
  /// Only server-issued cookies from the authenticated official API. Never
  /// extends a legacy session whose per-cookie expiration is unknown.
  public func refreshingQuarkCookies(from response: HTTPURLResponse, now: Double = Date().timeIntervalSince1970) -> PluginSession? {
    guard pluginID == "mtv.quark", domains == ["drive.quark.cn"], response.statusCode == 200,
      let url = response.url, url.scheme == "https", url.host == "drive.quark.cn",
      url.path.hasPrefix("/1/clouddrive/") else { return nil }
    let allowed: Set<String> = ["__pus", "__puus", "__kps", "__uid"]
    var values: [String: String] = [:]
    for part in cookie.split(separator: ";") {
      let fields = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
      guard fields.count == 2, allowed.contains(String(fields[0])) else { return nil }
      values[String(fields[0])] = String(fields[1])
    }
    var expiries = cookieExpiries ?? [:], changed = false
    let headers = response.allHeaderFields.reduce(into: [String: String]()) {
      if let key = $1.key as? String, let value = $1.value as? String { $0[key] = value }
    }
    for item in HTTPCookie.cookies(withResponseHeaderFields: headers, for: url) {
      let domain = item.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")).lowercased()
      guard allowed.contains(item.name), ["quark.cn", "drive.quark.cn"].contains(domain),
        item.path == "/", item.value.utf8.count <= 8192,
        !item.value.isEmpty, item.value.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 && $0 != ";" }),
        item.expiresDate.map({ $0.timeIntervalSince1970 > now }) ?? true else { continue }
      values[item.name] = item.value; expiries.removeValue(forKey: item.name)
      if let expiry = item.expiresDate { expiries[item.name] = expiry.timeIntervalSince1970 }
      changed = true
    }
    guard changed else { return nil }
    let header = values.keys.sorted().map { "\($0)=\(values[$0]!)" }.joined(separator: "; ")
    guard header.utf8.count <= 16000 else { return nil }
    return PluginSession(pluginID: pluginID, domains: domains, cookie: header,
      expiresAt: cookieExpiries == nil ? expiresAt : expiries.values.min(),
      cookieExpiries: cookieExpiries == nil ? nil : expiries, authIdentity:authIdentity)
  }
}

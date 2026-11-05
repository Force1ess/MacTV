import Foundation
import Testing
@testable import MTVCore

struct ChromeBilibiliSessionTests {
  private func payload(_ cookies: [[String: Any]], provider: String = "mtv.bilibili") throws -> Data {
    try JSONSerialization.data(withJSONObject: ["schema": 1, "provider": provider, "cookies": cookies])
  }
  private func cookie(_ name: String = "SESSDATA", domain: String = ".bilibili.com", value: String = "owned-fixture") -> [String: Any] {
    ["name": name, "domain": domain, "value": value, "path": "/", "hostOnly": false]
  }
  @Test func importsOnlySelectedPlatformAndAPIScope() throws {
    let session = try ChromePlatformSession.decode(payload([cookie(), cookie("bili_jct")]))
    #expect(session.pluginID == "mtv.bilibili")
    #expect(session.cookieHeader(for: URL(string: "https://api.bilibili.com/x/web-interface/nav")!) != nil)
    #expect(session.cookieHeader(for: URL(string: "https://www.bilibili.com/")!) == nil)
    #expect(session.cookieHeader(for: URL(string: "https://drive.quark.cn/")!) == nil)
  }
  @Test func rejectsMissingSessionWrongHostInjectionConflictAndExpiry() throws {
    var expired = cookie(); expired["expirationDate"] = 1
    var hostOnly = cookie(); hostOnly["hostOnly"] = true
    for cookies in [[cookie("bili_jct")], [cookie(domain: ".example.com")], [cookie(value: "a; b=c")],
      [cookie(), cookie(value: "conflict")], [expired], [hostOnly], [cookie("password")]] {
      #expect(throws: Error.self) { try ChromePlatformSession.decode(payload(cookies)) }
    }
    #expect(throws: Error.self) { try ChromePlatformSession.decode(payload([cookie()], provider: "other")) }
    #expect(throws: Error.self) { try ChromePlatformSession.decode(payload([cookie()], provider: "mtv.quark")) }
  }
  @Test func loginVerifierRequiresPositiveAuthenticatedAccount() {
    #expect(BilibiliImportedSessionValidator.accepts(Data(#"{"code":0,"data":{"isLogin":true,"mid":123}}"#.utf8)))
    for response in [#"{"code":0,"data":{"isLogin":false,"mid":123}}"#,
      #"{"code":-101,"data":{"isLogin":true,"mid":123}}"#,
      #"{"code":0,"data":{"isLogin":true,"mid":0}}"#, "{}", "not-json"] {
      #expect(!BilibiliImportedSessionValidator.accepts(Data(response.utf8)))
    }
  }
}

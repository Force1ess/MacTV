import Foundation
import Testing
@testable import MTVCore

struct ChromeCookieCipherTests {
  private func data(_ hex: String) -> Data {
    let chars = Array(hex); return Data(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...($0 + 1)]), radix: 16)! })
  }
  @Test func matchesIndependentOpenSSLFixtureAndDomainBinding() throws {
    // Generated with Ruby/OpenSSL, fake password/cookie only; not browser data.
    let key = try ChromeCookieCipher.key(password: Data("fixture-password".utf8))
    #expect(key == data("5d84e88b8d2628e23102b464d77a5bbd"))
    let encrypted = data("7631301b5542cde8f85f025502ff4c6585d75937c73653b2bb222cb01140a3760af8f35c9f7c67554fa00cd4a045c048fa9042")
    #expect(try ChromeCookieCipher.decrypt(encrypted, key: key, host: ".quark.cn", databaseVersion: 24) == "fixture-cookie")
    #expect(throws: Error.self) { try ChromeCookieCipher.decrypt(encrypted, key: key, host: ".example.com", databaseVersion: 24) }
    #expect(throws: Error.self) { try ChromeCookieCipher.decrypt(Data("v20unsupported".utf8), key: key, host: ".quark.cn", databaseVersion: 24) }
    #expect(throws: Error.self) { try ChromeCookieCipher.decrypt(encrypted, key: Data(repeating: 0, count: 16), host: ".quark.cn", databaseVersion: 24) }
  }
}

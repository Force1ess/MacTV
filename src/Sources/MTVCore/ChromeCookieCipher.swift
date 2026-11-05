import CommonCrypto
import CryptoKit
import Foundation

/// macOS Chromium v10 format only. No fallback passwords or unknown formats.
public enum ChromeCookieCipher {
  public static func key(password: Data) throws -> Data {
    guard !password.isEmpty, password.count <= 4096 else { throw MTVError.message("Chrome授权密钥无效") }
    let salt = Array("saltysalt".utf8)
    var key = [UInt8](repeating: 0, count: 16)
    let status = password.withUnsafeBytes { bytes in
      CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), bytes.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
        salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
    }
    guard status == kCCSuccess else { throw MTVError.message("Chrome授权密钥处理失败") }
    return Data(key)
  }
  public static func decrypt(_ value: Data, key: Data, host: String, databaseVersion: Int) throws -> String {
    guard value.count > 3, value.count <= 32768, value.prefix(3) == Data("v10".utf8), key.count == 16 else {
      throw MTVError.message("此Chrome加密格式尚不支持，请使用扫码登录")
    }
    let cipher = Data(value.dropFirst(3)), iv = [UInt8](repeating: 32, count: 16)
    var output = [UInt8](repeating: 0, count: cipher.count + 16), written = 0
    let capacity = output.count
    let status = key.withUnsafeBytes { secret in cipher.withUnsafeBytes { bytes in
      CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
        secret.baseAddress, key.count, iv, bytes.baseAddress, cipher.count, &output, capacity, &written)
    } }
    guard status == kCCSuccess else { throw MTVError.message("Chrome会话无法解锁，请重新授权或扫码登录") }
    var clear = Data(output.prefix(written))
    if databaseVersion >= 24 {
      let expected = Data(SHA256.hash(data: Data(host.utf8)))
      guard clear.count >= 32, clear.prefix(32) == expected else { throw MTVError.message("Chrome会话域名校验失败") }
      clear.removeFirst(32)
    }
    guard let text = String(data: clear, encoding: .utf8), !text.isEmpty else { throw MTVError.message("Chrome会话内容无效") }
    return text
  }
}

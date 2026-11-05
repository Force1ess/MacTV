import Foundation
import Security

/// File-based macOS keychains ignore LAContext.interactionNotAllowed in some
/// supported OS versions (Chromium FB16959400). Scope the legacy public switch
/// to one synchronous operation, serialize all MTV legacy-keychain access, and
/// restore the previous process state even when the operation fails. This does
/// not alter any item's permissions, the login keychain, or another process.
public enum LegacyKeychainInteraction {
  private static let lock = NSLock()
  public static func perform<T>(allowInteraction: Bool, _ operation: () throws -> T) throws -> T {
    guard lock.try() else {
      throw NSError(domain: "local.mtv.keychain-interaction", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "另一个系统授权请求仍在处理，请先完成或取消提示后重试。"])
    }
    defer { lock.unlock() }
    var previous: DarwinBoolean = false
    let observed = SecKeychainGetUserInteractionAllowed(&previous)
    guard observed == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(observed)) }
    let configured = SecKeychainSetUserInteractionAllowed(allowInteraction)
    guard configured == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(configured)) }
    defer { _ = SecKeychainSetUserInteractionAllowed(previous.boolValue) }
    return try operation()
  }
}

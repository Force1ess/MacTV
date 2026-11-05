import Foundation
import Security

/// Metadata about the exact Chrome item in this process's security session.
/// Never requests password data, changes an ACL, unlocks or writes a keychain.
public struct ChromeStorageAccess: Encodable, Sendable {
  var state = "unavailable"
  var lookupCode: OSStatus = errSecParam
  var keychainCode: OSStatus?
  var statusCode: OSStatus?
  var flags: SecKeychainStatus?
  let processID = ProcessInfo.processInfo.processIdentifier
  let checkedAt = Date().timeIntervalSince1970
  let secretRead = false
  var accessCode: OSStatus?
  var decryptACLs: [ACLObservation] = []
  struct ACLObservation: Encodable, Sendable {
    let status: OSStatus
    let applicationCount: Int
    let allowsAnyApplication: Bool
    let requiresPassphrase: Bool
    let containsInstalledMTVPath: Bool
  }

  public static func inspect() -> Self {
    do { return try LegacyKeychainInteraction.perform(allowInteraction: false) { inspectWithoutInteraction() } }
    catch {
      var value = Self(); value.lookupCode = OSStatus((error as NSError).domain == NSOSStatusErrorDomain ? (error as NSError).code : Int(errSecNotAvailable))
      return value
    }
  }
  private static func inspectWithoutInteraction() -> Self {
    var observation = Self()
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: "Chrome Safe Storage", kSecAttrAccount as String: "Chrome",
      kSecReturnRef as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
    var reference: CFTypeRef?
    observation.lookupCode = SecItemCopyMatching(query as CFDictionary, &reference)
    guard observation.lookupCode == errSecSuccess, let reference,
      CFGetTypeID(reference) == SecKeychainItemGetTypeID() else { return observation }
    let item = reference as! SecKeychainItem
    var access: SecAccess?
    observation.accessCode = SecKeychainItemCopyAccess(item, &access)
    if observation.accessCode == errSecSuccess, let access,
      let list = SecAccessCopyMatchingACLList(access, kSecACLAuthorizationDecrypt) as? [SecACL], list.count <= 64 {
      for acl in list {
        var apps: CFArray?, label: CFString?, prompt: SecKeychainPromptSelector = []
        let status = SecACLCopyContents(acl, &apps, &label, &prompt)
        let applications = apps as? [SecTrustedApplication] ?? []
        // Do not expose names/paths of other trusted applications or parse
        // opaque requirement blobs. Only recognize the exact installed path
        // when the public data accessor returns a plain UTF-8 path.
        let containsMTV = applications.prefix(256).contains { app in
          var bytes: CFData?
          guard SecTrustedApplicationCopyData(app, &bytes) == errSecSuccess,
            let bytes, CFDataGetLength(bytes) <= 4096,
            let path = String(data: bytes as Data, encoding: .utf8) else { return false }
          return path.trimmingCharacters(in: CharacterSet(charactersIn: "\0")) == "/Applications/MacTV.app"
        }
        observation.decryptACLs.append(ACLObservation(status: status, applicationCount: applications.count,
          allowsAnyApplication: status == errSecSuccess && apps == nil, requiresPassphrase: prompt.contains(.requirePassphase),
          containsInstalledMTVPath: containsMTV))
      }
    }
    var keychain: SecKeychain?
    observation.keychainCode = SecKeychainItemCopyKeychain(item, &keychain)
    guard observation.keychainCode == errSecSuccess, let keychain else { return observation }
    var flags: SecKeychainStatus = 0
    observation.statusCode = SecKeychainGetStatus(keychain, &flags)
    guard observation.statusCode == errSecSuccess else { return observation }
    observation.flags = flags
    observation.state = flags & UInt32(kSecUnlockStateStatus) == 0 ? "locked" : "unlocked"
    return observation
  }
}

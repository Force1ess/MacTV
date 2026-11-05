import Darwin
import Foundation
import Security

// Keep this independent target free of MTVCore/UI dependencies. Its code
// identity must survive ordinary host-app rebuilds: self-signed legacy
// keychain partitions identify a process by CDHash, not its certificate alone.
func reply(_ status: OSStatus, reason: String? = nil, secret: Data? = nil) -> Never {
  var value: [String: Any] = ["schema": 1, "status": Int(status)]
  if let reason { value["reason"] = reason }
  if let secret { value["secret"] = secret.base64EncodedString() }
  if let bytes = try? JSONSerialization.data(withJSONObject: value) { FileHandle.standardOutput.write(bytes) }
  exit(0)
}
func signingInfo(_ code: SecCode) -> [String: Any]? {
  var value: CFDictionary?
  var staticCode: SecStaticCode?
  guard SecCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil) == errSecSuccess,
    SecCodeCopyStaticCode(code, SecCSFlags(rawValue: 0), &staticCode) == errSecSuccess, let staticCode,
    SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &value) == errSecSuccess else { return nil }
  return value as? [String: Any]
}
func trustedParent() -> pid_t? {
  let pid = getppid()
  guard pid > 1 else { return nil }
  var parent: SecCode?, own: SecCode?
  guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid as String: pid] as CFDictionary,
    SecCSFlags(rawValue: 0), &parent) == errSecSuccess,
    SecCodeCopySelf(SecCSFlags(rawValue: 0), &own) == errSecSuccess,
    let parent, let own, let parentInfo = signingInfo(parent), let ownInfo = signingInfo(own),
    parentInfo[kSecCodeInfoIdentifier as String] as? String == "local.mtv.preview",
    let parentCertificates = parentInfo[kSecCodeInfoCertificates as String] as? [SecCertificate],
    let ownCertificates = ownInfo[kSecCodeInfoCertificates as String] as? [SecCertificate],
    let parentLeaf = parentCertificates.first, let ownLeaf = ownCertificates.first,
    (SecCertificateCopyData(parentLeaf) as Data) == (SecCertificateCopyData(ownLeaf) as Data)
  else { return nil }
  return pid
}
if Array(CommandLine.arguments.dropFirst()) == ["--chrome-reader-version"] {
  FileHandle.standardOutput.write(Data("{\"schema\":1,\"component\":\"chrome-reader\",\"version\":1}".utf8)); exit(0)
}
if CommandLine.arguments.dropFirst().first == "--chrome-storage-read" {
  let arguments = Array(CommandLine.arguments.dropFirst())
  guard arguments.count == 2, ["--no-ui", "--allow-ui"].contains(arguments[1]) else { reply(errSecParam, reason: "invalid-reader-arguments") }
  guard let parent = trustedParent() else { reply(errSecAuthFailed, reason: "untrusted-parent") }
  // If the host exits during a system prompt, close this request too. Never
  // leave an orphaned security request behind after an app update or quit.
  let parentWatch = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
  parentWatch.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
  parentWatch.setEventHandler { if getppid() != parent { _exit(0) } }
  parentWatch.resume()
  let allowed = arguments[1] == "--allow-ui"
  let configured = SecKeychainSetUserInteractionAllowed(allowed)
  guard configured == errSecSuccess else { reply(configured) }
  // Exactly one existing Chrome item. No arbitrary queries, writes, ACL edits,
  // browser database access, secret cache, plugin access, or network operations.
  let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "Chrome Safe Storage", kSecAttrAccount as String: "Chrome",
    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
  var value: CFTypeRef?
  let status = SecItemCopyMatching(query as CFDictionary, &value)
  guard status == errSecSuccess, let secret = value as? Data, !secret.isEmpty, secret.count <= 4096 else { reply(status == errSecSuccess ? errSecDecode : status) }
  guard getppid() == parent else { _exit(0) }
  // Only the validated native parent receives this anonymous-pipe response.
  reply(errSecSuccess, secret: secret)
}

// Chrome launches this registered binary. Execute the main signed app binary
// in native-message mode for platform validation and local credential storage.
let main = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
  .deletingLastPathComponent().appendingPathComponent("MTV").path
let values = [main, "--chrome-quark-native-import"] + Array(CommandLine.arguments.dropFirst())
var argv = values.map { strdup($0) }; argv.append(nil)
main.withCString { path in _ = execv(path, &argv) }
for value in argv { free(value) }
exit(1)

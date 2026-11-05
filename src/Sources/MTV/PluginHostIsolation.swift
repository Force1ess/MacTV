import Foundation
import Security
import MTVCore

enum PluginHostIsolation {
  static func validate(_ helper: URL) throws {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(helper as CFURL, [], &code) == errSecSuccess, let code,
      SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
      throw MTVError.message("插件隔离宿主签名无效，拒绝退回未隔离进程")
    }
    var raw: CFDictionary?
    guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
      let info = raw as? [String: Any], info[kSecCodeInfoIdentifier as String] as? String == "local.mtv.plugin-host",
      let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
      Set(entitlements.keys) == ["com.apple.security.app-sandbox"],
      entitlements["com.apple.security.app-sandbox"] as? Bool == true else {
      throw MTVError.message("插件宿主隔离权限不符合预期，已拒绝启动")
    }
  }
}

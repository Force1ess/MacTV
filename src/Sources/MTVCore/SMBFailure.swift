import Darwin
import Foundation

/// Diagnostic evidence only: access denial alone cannot establish a TCC decision.
public struct SMBFailure: LocalizedError, Sendable, Equatable {
  public enum Stage: String, Sendable { case mount, mountValidation, directoryVerification, directoryRead }
  public enum Category: String, Sendable { case mountChanged, accessDenied, authentication, missing, notDirectory, network, timeout, other }
  public struct Code: Sendable, Equatable { public let domain: String; public let value: Int }
  public let stage: Stage
  public let category: Category
  public let codes: [Code]
  public init(_ error: Error, stage: Stage) {
    if let existing = error as? Self { self = existing; return }
    self.stage = stage
    var current = error as NSError, chain: [Code] = []
    for _ in 0..<4 {
      chain.append(Code(domain: String(current.domain.prefix(64)).filter { !$0.isNewline && !$0.isASCIIControl }, value: current.code))
      guard let next = current.userInfo[NSUnderlyingErrorKey] as? NSError else { break }
      current = next
    }
    codes = chain
    func posix(_ values: [Int32]) -> Bool { chain.contains { $0.domain == NSPOSIXErrorDomain && values.contains(Int32(clamping: $0.value)) } }
    if chain.contains(where: { $0.domain == "local.mtv.smb.mount-identity" }) { category = .mountChanged }
    else if posix([EPERM, EACCES]) || chain.contains(where: { $0.domain == NSCocoaErrorDomain && $0.value == CocoaError.fileReadNoPermission.rawValue }) { category = .accessDenied }
    else if posix([EAUTH]) { category = .authentication }
    else if posix([ENOENT]) || chain.contains(where: { $0.domain == NSCocoaErrorDomain && [CocoaError.fileReadNoSuchFile.rawValue, CocoaError.fileNoSuchFile.rawValue].contains($0.value) }) { category = .missing }
    else if posix([ENOTDIR]) { category = .notDirectory }
    else if posix([ETIMEDOUT]) || chain.contains(where: { $0.domain == NSURLErrorDomain && $0.value == NSURLErrorTimedOut }) { category = .timeout }
    else if posix([ENOTCONN, ECONNRESET, ENETDOWN, ENETUNREACH, EHOSTUNREACH, ECONNREFUSED])
      || chain.contains(where: { $0.domain == NSURLErrorDomain && [NSURLErrorNetworkConnectionLost, NSURLErrorCannotConnectToHost, NSURLErrorNotConnectedToInternet, NSURLErrorCannotFindHost].contains($0.value) }) { category = .network }
    else { category = .other }
  }
  public static func netFS(_ status: Int32) -> Self {
    // NetFS also uses negative OSStatus values. Do not label every unknown status
    // as an authentication failure, and never attach a URL or supplied secret.
    Self(NSError(domain: status > 0 ? NSPOSIXErrorDomain : NSOSStatusErrorDomain, code: Int(status)), stage: .mount)
  }
  public static func mountChanged(_ reason: Int = 2) -> Self {
    Self(NSError(domain: "local.mtv.smb.mount-identity", code: reason), stage: .mountValidation)
  }
  public var errorDescription: String? {
    let whereFailed = stage == .mount ? "SMB 连接失败。" : (stage == .mountValidation ? "SMB 挂载身份检查失败。" : (stage == .directoryVerification ? "SMB 挂载后的目录检查失败。" : "SMB 目录读取失败。"))
    let help: String
    switch category {
    case .mountChanged: help = "共享已卸载或挂载身份发生变化，请重新连接。未将残留的本地目录当作网络共享。"
    case .accessDenied: help = "访问被拒绝。请检查 macOS「隐私与安全性 → 文件与文件夹」中的网络卷访问，以及 NAS 目录权限；仅凭此错误无法区分两者。"
    case .authentication: help = "请检查账号密码或访客权限。"
    case .missing: help = "共享或目录不存在；可检查地址，或明确选择共享根目录。"
    case .notDirectory: help = "所选路径不是目录，请选择影片文件夹。"
    case .network: help = "网络连接不可用，请检查服务器和网络后重试。"
    case .timeout: help = "读取或连接超时。若系统正在询问网络卷权限，请先处理提示；前次读取结束后可重试。"
    case .other: help = stage == .mountValidation ? "无法确认当前共享挂载，已停止读取，请重新连接。" : "请核对服务器、共享与目录访问设置。"
    }
    return whereFailed + help
  }
  public var diagnostic: String { stage.rawValue + " · " + codes.map { $0.domain + " " + String($0.value) }.joined(separator: " → ") }
}

private extension Character {
  var isASCIIControl: Bool { unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
}

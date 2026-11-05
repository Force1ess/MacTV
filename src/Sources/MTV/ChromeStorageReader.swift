import Foundation
import Security
import MTVCore

/// One cancelable native read, owned by one login attempt. No files or key cache.
final class ChromeStorageReadOperation: @unchecked Sendable {
  private let lock = NSLock()
  private var process: Process?
  private var cancelled = false
  func start(_ process: Process) throws {
    lock.lock(); defer { lock.unlock() }
    guard !cancelled else { throw CancellationError() }
    try process.run(); self.process = process
  }
  func finish(_ process: Process) {
    lock.lock(); defer { lock.unlock() }
    if self.process === process { self.process = nil }
  }
  func cancel() {
    lock.lock(); cancelled = true; let active = process; lock.unlock()
    if let active, active.isRunning { active.terminate() }
  }
  var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
  deinit { cancel() }
}

enum ChromeStorageReader {
  private static func validate(_ helper: URL) throws {
    var code: SecStaticCode?, ownStatic: SecStaticCode?, own: SecCode?, helperInfo: CFDictionary?, ownInfo: CFDictionary?
    guard SecStaticCodeCreateWithPath(helper as CFURL, SecCSFlags(rawValue: 0), &code) == errSecSuccess,
      let code, SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
      SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &helperInfo) == errSecSuccess,
      SecCodeCopySelf(SecCSFlags(rawValue: 0), &own) == errSecSuccess, let own,
      SecCodeCopyStaticCode(own, SecCSFlags(rawValue: 0), &ownStatic) == errSecSuccess, let ownStatic,
      SecCodeCopySigningInformation(ownStatic, SecCSFlags(rawValue: kSecCSSigningInformation), &ownInfo) == errSecSuccess,
      let helperValues = helperInfo as? [String: Any], let ownValues = ownInfo as? [String: Any],
      helperValues[kSecCodeInfoIdentifier as String] as? String == "MTVChromeBridge",
      let helperChain = helperValues[kSecCodeInfoCertificates as String] as? [SecCertificate],
      let ownChain = ownValues[kSecCodeInfoCertificates as String] as? [SecCertificate],
      let helperLeaf = helperChain.first, let ownLeaf = ownChain.first,
      (SecCertificateCopyData(helperLeaf) as Data) == (SecCertificateCopyData(ownLeaf) as Data)
    else { throw MTVError.message(L("登录组件身份校验失败，请使用固定签名的安装包，或扫码登录。")) }
  }
  private struct Reply: Decodable {
    let schema: Int
    let status: Int32
    let reason: String?
    let secret: Data?
  }
  static func read(allowInteraction: Bool, operation: ChromeStorageReadOperation) throws -> Data {
    guard let executable = Bundle.main.executableURL else { throw MTVError.message(L("登录组件缺失，请重新安装 MacTV。")) }
    let helper = executable.deletingLastPathComponent().appendingPathComponent("MTVChromeBridge")
    guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw MTVError.message(L("登录组件缺失，请重新安装 MacTV。")) }
    try validate(helper)
    let process = Process(), output = Pipe()
    process.executableURL = helper
    process.arguments = ["--chrome-storage-read", allowInteraction ? "--allow-ui" : "--no-ui"]
    process.standardOutput = output; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
    try operation.start(process)
    defer { operation.finish(process) }
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    timer.schedule(deadline: .now() + .seconds(allowInteraction ? 300 : 10))
    timer.setEventHandler { operation.cancel() }; timer.resume()
    defer { timer.cancel() }
    var bytes = Data()
    while let part = try output.fileHandleForReading.read(upToCount: 16385 - bytes.count), !part.isEmpty {
      bytes.append(part)
      guard bytes.count <= 16384 else { operation.cancel(); throw MTVError.message(L("登录组件响应无效。")) }
    }
    process.waitUntilExit()
    guard !operation.isCancelled else { throw CancellationError() }
    guard process.terminationReason == .exit, process.terminationStatus == 0,
      let reply = try? JSONDecoder().decode(Reply.self, from: bytes), reply.schema == 1 else {
      throw MTVError.message(L("登录组件未能完成读取，请重试或扫码登录。"))
    }
    if reply.reason == "untrusted-parent" { throw MTVError.message(L("登录组件的应用身份校验失败，请重新安装 MacTV。")) }
    guard reply.status == errSecSuccess, let secret = reply.secret, !secret.isEmpty, secret.count <= 4096 else {
      let message: String
      switch reply.status {
      case errSecUserCanceled: message = L("已取消 Chrome 登录授权。")
      case errSecItemNotFound: message = L("找不到 Chrome 登录钥匙。请先在 Chrome 登录对应平台，或扫码登录。")
      case errSecInteractionNotAllowed, errSecAuthFailed: message = L("Chrome 登录需要授权，请选择“授权并导入”。")
      default: message = L("暂时无法读取 Chrome 登录，请重试或扫码登录。")
      }
      throw NSError(domain: NSOSStatusErrorDomain, code: Int(reply.status), userInfo: [NSLocalizedDescriptionKey:
        message])
    }
    return secret
  }
}

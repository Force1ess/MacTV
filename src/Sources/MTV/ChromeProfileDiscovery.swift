import Foundation

@MainActor enum ChromeProfileDiscovery {
  struct Result {
    let profiles: [LocalChromeQuark.Profile]
    let savedAccessWarning: NSError?
  }
  /// A stale saved bookmark does not establish that the app's current privacy
  /// permission is denied. The same Chrome path must still pass macOS access
  /// checks; there are no alternate paths, helpers or credential reads here.
  static func load(
    restore: @MainActor () throws -> Void = { try ChromeFolderAccess.restoreIfAvailable() },
    read: @MainActor () async throws -> [LocalChromeQuark.Profile] = {
      try await Task.detached { try LocalChromeQuark.profiles() }.value
    }
  ) async throws -> Result {
    try Task.checkCancellation()
    var warning: NSError?
    do { try restore() } catch { warning = error as NSError }
    try Task.checkCancellation()
    let profiles = try await read()
    try Task.checkCancellation()
    return Result(profiles: profiles, savedAccessWarning: warning)
  }
  static func message(for error: Error) -> String {
    let failure = error as NSError
    if failure.domain == NSCocoaErrorDomain {
      switch failure.code {
      case CocoaError.fileReadNoPermission.rawValue:
        return "目前无法读取Chrome资料。如果已经授权，请重新打开MacTV后再试；也可以通过Chrome扩展导入或扫码登录。"
      case CocoaError.fileNoSuchFile.rawValue, CocoaError.fileReadNoSuchFile.rawValue:
        return "这台Mac还没有Chrome资料。请先打开Chrome并登录，再回来导入。"
      default: break
      }
    }
    return "Chrome资料暂时无法读取。请稍后重试，或使用扫码登录。"
  }
}

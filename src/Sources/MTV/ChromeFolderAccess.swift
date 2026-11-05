import AppKit
import MTVCore

/// Explicit Powerbox access to Chrome's folder. No TCC edits or helper identity.
@MainActor enum ChromeFolderAccess {
  private static var held: (URL, Bool)?
  private static let store = LocalCredentialStore(service: "local.mtv.chrome-folder-access")
  static func isExpectedFolder(_ url: URL) -> Bool {
    url.isFileURL && (url.host == nil || url.host == "" || url.host == "localhost")
      && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
      && url.standardizedFileURL.path == LocalChromeQuark.chromeRoot.standardizedFileURL.path
  }
  static func restoreIfAvailable() throws {
    guard held == nil, let data = try store.load(account: "chrome-root") else { return }
    var stale = false
    let url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
    guard !stale, isExpectedFolder(url) else { throw MTVError.message(L("Chrome文件夹许可需要重新选择，请使用“允许访问Chrome资料”。")) }
    held = (url, url.startAccessingSecurityScopedResource())
  }
  /// System privacy approval cannot be granted by MTV. Open the exact settings
  /// page; the user only enables MTV, without finding hidden Chrome directories.
  static func openPrivacySettings() {
    guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
    NSWorkspace.shared.open(url)
  }
}

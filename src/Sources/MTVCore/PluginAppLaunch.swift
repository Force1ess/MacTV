import Foundation

/// A fixed, reviewable application action. Scripts cannot supply a different
/// URL at runtime, invoke a shell, or terminate the launched application.
public struct PluginAppLaunch: Codable, Equatable, Sendable {
  public let bundleID: String
  public let url: String
  public let returnWhen: String
  public let instructions: [String:String]?
  public let windowTitles: [String]?
  public let preferredPresentation: String?
  public let readyWhen: String?
  public func validate() throws {
    guard bundleID.range(of: #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil,
      let value = URL(string: url), let scheme = value.scheme,
      scheme.range(of: #"^[a-z][a-z0-9+-]{1,31}$"#, options: .regularExpression) != nil,
      !["http", "https", "file", "data", "javascript", "ssh", "smb", "ftp", "mailto"].contains(scheme),
      value.user == nil, value.password == nil, value.port == nil,
      value.query == nil, value.fragment == nil, !url.contains("%"), url.utf8.count <= 512,
      url.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value < 127 }),
      ["fullscreen-window-closes","matched-window-closes"].contains(returnWhen),
      preferredPresentation==nil || ["fullscreen","unchanged"].contains(preferredPresentation!),
      preferredPresentation != "fullscreen" || windowTitles != nil,
      readyWhen==nil || ["application-running","visible-window"].contains(readyWhen!),
      windowTitles.map({ !$0.isEmpty && $0.count<=8 && $0.allSatisfy({ !$0.isEmpty && $0.count<=120 && $0.unicodeScalars.allSatisfy({$0.value>=32 && $0.value != 127}) }) }) ?? true,
      returnWhen != "matched-window-closes" || windowTitles != nil else { throw MTVError.message("Invalid application-launch declaration") }
  }
}

/// Metadata-only lifecycle tracking; no screen pixels or window titles.
public struct FullscreenSessionTracker: Sendable {
  public private(set) var windowID: Int?
  public private(set) var finished = false
  private let baseline: Set<Int>
  private var missingSamples = 0
  public init(baseline: Set<Int>) { self.baseline = baseline }
  public mutating func observe(fullscreenWindows: Set<Int>, applicationRunning: Bool) {
    guard !finished else { return }
    if windowID == nil { windowID = fullscreenWindows.subtracting(baseline).sorted().first; return }
    if let watched = windowID, applicationRunning, let replacement = fullscreenWindows.subtracting(baseline).sorted().first,
      !fullscreenWindows.contains(watched) { windowID = replacement; missingSamples = 0; return }
    if let windowID, applicationRunning && fullscreenWindows.contains(windowID) { missingSamples = 0 }
    else { missingSamples += 1; if missingSamples >= 2 { finished = true } }
  }
}

public enum LauncherReturnPolicy {
  public static func shouldActivate(applicationRunning: Bool, selectedApplicationFront: Bool, hostFront: Bool, lastSelectedApplicationFront: Bool) -> Bool {
    selectedApplicationFront || hostFront || (!applicationRunning && lastSelectedApplicationFront)
  }
}

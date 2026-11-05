import Foundation

/// Display branding is independent of the persisted application/protocol IDs.
enum AppBrand {
  static let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "MacTV"
}

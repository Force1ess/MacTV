import AppKit

@MainActor enum BrandIcon {
  private static let images: [String: NSImage] = {
    guard let root = Bundle.main.resourceURL?.appendingPathComponent("BrandIcons") else { return [:] }
    return ["mtv.bilibili": ["bilibili.png", "bilibili.jpg"], "mtv.quark": ["quark.ico"]].reduce(into: [:]) { result, entry in
      for filename in entry.value {
        if let image = NSImage(contentsOf: root.appendingPathComponent(filename)) {
          result[entry.key] = image
          break
        }
      }
    }
  }()
  static func image(_ pluginID: String) -> NSImage? { images[pluginID] }
}

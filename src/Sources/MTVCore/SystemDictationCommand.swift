import AppKit

@MainActor public enum SystemDictationCommand {
  public struct Entry: Equatable, Sendable {
    public let selector: String
    public let enabled: Bool
    public let targetClass: String
    public let resolvedTargetClass: String
    public let responderTargetClass: String
  }
  /// Own-menu command metadata only: no text drafts, speech or menu labels.
  public static func entries(in menu: NSMenu) -> [Entry] {
    var result: [Entry] = []
    for item in menu.items {
      if let action = item.action {
        let selector = NSStringFromSelector(action)
        if selector.count <= 128, selector.lowercased().contains("dictation") {
          func name(_ target: Any?) -> String { target.map { String(describing: type(of: $0)) } ?? "none" }
          result.append(Entry(selector: selector, enabled: item.isEnabled,
            targetClass: name(item.target),
            resolvedTargetClass: name(NSApp?.target(forAction: action, to: item.target, from: item)),
            responderTargetClass: name(NSApp?.target(forAction: action, to: nil, from: item))))
        }
      }
      if let submenu = item.submenu { result.append(contentsOf: entries(in: submenu)) }
      if result.count >= 32 { return Array(result.prefix(32)) }
    }
    return result
  }
  /// Only dispatch the system's start command, never stop/preferences commands
  /// that happen to contain the same word in their selector.
  public static func startItem(in menu: NSMenu) -> NSMenuItem? {
    item(in: menu, selector: "startDictation:")
  }
  public static func stopItem(in menu: NSMenu) -> NSMenuItem? {
    item(in: menu, selector: "stopDictation:")
  }
  private static func item(in menu: NSMenu, selector: String) -> NSMenuItem? {
    for item in menu.items {
      if let action = item.action, NSStringFromSelector(action) == selector, item.isEnabled { return item }
      if let submenu = item.submenu, let found = self.item(in: submenu, selector: selector) { return found }
    }
    return nil
  }
  public static func refresh(_ menu: NSMenu) {
    menu.update()
    for item in menu.items { if let submenu = item.submenu { refresh(submenu) } }
  }
}

import AppKit
import ApplicationServices
import MTVCore

/// Read-only, bounded diagnostics for the application currently selected by a
/// launcher. Text-field values, passwords and arbitrary process IDs are excluded.
enum ApplicationAccessibility {
  static var available: Bool { AXIsProcessTrusted() }
  private static func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var result: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element,attribute as CFString,&result) == .success else { return nil }
    return result
  }
  static func matchingWindows(pids: Set<pid_t>, titles: [String]) -> Set<Int>? {
    guard AXIsProcessTrusted() else { return nil }
    let visible=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
    let deadline=ProcessInfo.processInfo.systemUptime+2
    var ids=Set<Int>(), readable=false
    for pid in pids.sorted() {
      guard ProcessInfo.processInfo.systemUptime<deadline, !Task.isCancelled else { return nil }
      let app=AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app,0.05)
      guard let windows=read(app,kAXWindowsAttribute) as? [AXUIElement] else { continue }
      readable=true
      for window in windows.prefix(16) {
        guard ProcessInfo.processInfo.systemUptime<deadline, !Task.isCancelled else { return nil }
        guard titles.contains(read(window,kAXTitleAttribute) as? String ?? ""),
          read(window,kAXMinimizedAttribute) as? Bool != true, read(window,"AXHidden") as? Bool != true,
          let position=read(window,kAXPositionAttribute), CFGetTypeID(position)==AXValueGetTypeID(),
          let size=read(window,kAXSizeAttribute), CFGetTypeID(size)==AXValueGetTypeID() else { continue }
        var point=CGPoint.zero, dimensions=CGSize.zero
        guard AXValueGetValue(position as! AXValue,.cgPoint,&point), AXValueGetValue(size as! AXValue,.cgSize,&dimensions) else { continue }
        for item in visible {
          guard item[kCGWindowOwnerPID as String] as? Int32==pid, item[kCGWindowLayer as String] as? Int==0,
            let raw=item[kCGWindowBounds as String] as? [String:Any], let bounds=CGRect(dictionaryRepresentation:raw as CFDictionary),
            abs(bounds.minX-point.x)<4, abs(bounds.minY-point.y)<4, abs(bounds.width-dimensions.width)<4, abs(bounds.height-dimensions.height)<4,
            let id=item[kCGWindowNumber as String] as? Int else { continue }
          ids.insert(id)
        }
      }
    }
    return readable ? ids:nil
  }
  static func perform(pids: Set<pid_t>, titles: [String], action: String) -> Bool {
    guard AXIsProcessTrusted(), ["fullscreen","close"].contains(action) else { return false }
    let deadline=ProcessInfo.processInfo.systemUptime+2
    for pid in pids.sorted() {
      guard ProcessInfo.processInfo.systemUptime<deadline, !Task.isCancelled else { return false }
      let app=AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app,0.05)
      for window in (read(app,kAXWindowsAttribute) as? [AXUIElement] ?? []).prefix(16) {
        guard ProcessInfo.processInfo.systemUptime<deadline else { return false }
        guard titles.contains(read(window,kAXTitleAttribute) as? String ?? ""), !Task.isCancelled else { continue }
        if action=="fullscreen" {
          if read(window,"AXFullScreen") as? Bool == true { return true }
          var settable=DarwinBoolean(false)
          guard AXUIElementIsAttributeSettable(window,"AXFullScreen" as CFString,&settable) == .success, settable.boolValue else { continue }
          return AXUIElementSetAttributeValue(window,"AXFullScreen" as CFString,kCFBooleanTrue) == .success
        }
        if let button=read(window,kAXCloseButtonAttribute), CFGetTypeID(button)==AXUIElementGetTypeID() {
          return AXUIElementPerformAction(button as! AXUIElement,kAXPressAction as CFString) == .success
        }
      }
    }
    return false
  }
  /// Menu metadata only; caller supplies fixed command titles. Unmatched labels
  /// are discarded, and no value/text-input/transcript attributes are read.
  static func inspectMenuCommands(pids: Set<pid_t>, titles: Set<String>) -> [String: Any] {
    guard AXIsProcessTrusted() else { return ["available": false, "reason": "accessibility-permission"] }
    let accepted = Set(titles.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    var commands: [[String: Any]] = [], visited = 0, menuBarsRead = 0
    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
      guard !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline else { return nil }
      AXUIElementSetMessagingTimeout(element, 0.05)
      return read(element, name)
    }
    for pid in pids.sorted() {
      let app = AXUIElementCreateApplication(pid); AXUIElementSetMessagingTimeout(app, 0.05)
      guard let raw = attribute(app, kAXMenuBarAttribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { continue }
      menuBarsRead += 1
      var queue: [(AXUIElement, Int)] = [(raw as! AXUIElement, 0)]
      while !queue.isEmpty, visited < 320,
        !Task.isCancelled, ProcessInfo.processInfo.systemUptime < deadline {
        let (item, depth) = queue.removeFirst()
        visited += 1
        let role = attribute(item, kAXRoleAttribute) as? String ?? ""
        if role == "AXMenuItem", let title = attribute(item, kAXTitleAttribute) as? String,
          accepted.contains(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
          let character = attribute(item, "AXMenuItemCmdChar") as? String ?? ""
          let modifiers = attribute(item, "AXMenuItemCmdModifiers") as? Int ?? -1
          commands.append(["title": LocalControlJSON.safeText(String(title.prefix(100))),
            "character": LocalControlJSON.safeText(String(character.prefix(4))), "modifiers": modifiers,
            "enabled": attribute(item, kAXEnabledAttribute) as? Bool ?? false])
        }
        if depth < 6 {
          for child in (attribute(item, kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(40) {
            queue.append((child, depth + 1))
          }
        }
      }
    }
    return ["available": true, "menuBarsRead": menuBarsRead, "commands": commands, "visited": visited,
      "truncated": visited >= 320 || ProcessInfo.processInfo.systemUptime >= deadline]
  }
  static func inspect(pids: Set<pid_t>) -> [String:Any] {
    guard AXIsProcessTrusted() else { return ["available":false,"reason":"accessibility-permission"] }
    let deadline=ProcessInfo.processInfo.systemUptime+2
    var buttons: [String]=[], windows: [[String:Any]]=[], visited=0, roles: [String:Int]=[:]
    func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
      guard ProcessInfo.processInfo.systemUptime<deadline else { return nil }
      var result: CFTypeRef?
      guard AXUIElementCopyAttributeValue(element,attribute as CFString,&result) == .success else { return nil }
      return result
    }
    for pid in pids.sorted() {
      guard visited<160, ProcessInfo.processInfo.systemUptime<deadline else { break }
      let application=AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(application,0.05)
      let roots=value(application,kAXWindowsAttribute) as? [AXUIElement] ?? []
      var stack=roots.map { ($0,0) }
      for window in roots.prefix(8) {
        windows.append(["pid":pid,"title":LocalControlJSON.safeText(String((value(window,kAXTitleAttribute) as? String ?? "").prefix(120))),"fullscreen":value(window,"AXFullScreen") as? Bool ?? false,"minimized":value(window,kAXMinimizedAttribute) as? Bool ?? false])
      }
      while let (element,depth)=stack.popLast(), visited<160, ProcessInfo.processInfo.systemUptime<deadline {
        visited += 1
        let role=value(element,kAXRoleAttribute) as? String ?? ""
        roles[String(role.prefix(80)), default: 0] += 1
        if ["AXTextField","AXSecureTextField","AXTextArea"].contains(role) { continue }
        if ["AXButton","AXMenuButton"].contains(role), buttons.count<40 {
          let label = [kAXTitleAttribute, kAXDescriptionAttribute].compactMap { value(element,$0) as? String }.first { !$0.isEmpty }
          if let label { buttons.append(LocalControlJSON.safeText(String(label.prefix(100)))) }
        }
        if depth<8 { for child in (value(element,kAXChildrenAttribute) as? [AXUIElement] ?? []).prefix(40) { stack.append((child,depth+1)) } }
      }
    }
    return ["available":true,"windows":windows,"buttons":buttons,"visited":visited,"roles":roles,
      "bounded":visited>=160 || ProcessInfo.processInfo.systemUptime>=deadline]
  }
}

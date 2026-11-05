import AppKit
import Testing
@testable import MTVCore

@MainActor struct SystemDictationCommandTests {
  @Test func onlyEnabledSystemStartIsEligible() {
    let menu = NSMenu(); menu.autoenablesItems = false
    let preferences = NSMenuItem(title: "Preferences", action: NSSelectorFromString("showDictationPreferences:"), keyEquivalent: "")
    let stop = NSMenuItem(title: "Stop", action: NSSelectorFromString("stopDictation:"), keyEquivalent: "")
    let start = NSMenuItem(title: "Start", action: NSSelectorFromString("startDictation:"), keyEquivalent: "")
    menu.addItem(preferences); menu.addItem(stop)
    #expect(SystemDictationCommand.startItem(in: menu) == nil)
    #expect(SystemDictationCommand.stopItem(in: menu) === stop)
    stop.isEnabled = false
    #expect(SystemDictationCommand.stopItem(in: menu) == nil)
    stop.isEnabled = true
    let holder = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
    let edit = NSMenu(); edit.autoenablesItems = false; edit.addItem(start); holder.submenu = edit; menu.addItem(holder)
    #expect(SystemDictationCommand.startItem(in: menu) === start)
    #expect(SystemDictationCommand.entries(in: menu).map(\.selector) == ["showDictationPreferences:", "stopDictation:", "startDictation:"])
    start.isEnabled = false
    #expect(SystemDictationCommand.startItem(in: menu) == nil)
    #expect(SystemDictationCommand.entries(in: menu).last?.enabled == false)
  }
}

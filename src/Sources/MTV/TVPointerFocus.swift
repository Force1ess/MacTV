import AppKit
import SwiftUI

@MainActor enum TVPointerFocus {
  private(set) static var acceptsHover = false
  private(set) static var cursorHideRequested = false
  private static var lastLocation = NSEvent.mouseLocation
  static func pointerMoved() {
    let location = NSEvent.mouseLocation
    guard location != lastLocation else { return }
    lastLocation = location
    acceptsHover = true
  }
  static func setPlaybackCursorHidden(_ hidden: Bool) {
    guard !hidden || (NSApp.isActive && NSApp.keyWindow?.identifier?.rawValue == "MTVMainWindow") else { return }
    // AppKit reveals the cursor on the next real mouse movement, even if
    // the app loses focus before its playback controls are shown again.
    NSCursor.setHiddenUntilMouseMoves(hidden)
    cursorHideRequested = hidden
  }
  static func remoteInput() {
    lastLocation = NSEvent.mouseLocation
    acceptsHover = false
  }
}

extension View {
  func tvPointerFocus(_ action: @escaping () -> Void) -> some View {
    onContinuousHover { phase in
      if case .active = phase, TVPointerFocus.acceptsHover { action() }
    }
  }
}

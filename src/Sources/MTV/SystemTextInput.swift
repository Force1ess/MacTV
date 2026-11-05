import AppKit
import SwiftUI
import MTVCore

/// The TV keyboard keeps its remote focus grid. A real NSTextView supplies
/// the insertion point and NSTextInputClient contract used by macOS dictation.
@MainActor final class MTVSystemTextView: NSTextView {
  weak var model: AppModel?
  var target: TextEntryTarget = .search
  var sessionID = UUID()
  var acceptingInput = true
  var updatingFromModel = false
  private var insertRequests = 0
  private var markedRequests = 0
  private var changeEvents = 0
  private var rejectedChanges = 0
  private var lastRejection = "none"
  private var diagnosticsEnabled: Bool { CommandLine.arguments.contains("--enable-control") || CommandLine.arguments.contains("--ui-smoke") }
  var nativeInputEvents: [String: Any] {
    ["insertRequests": insertRequests, "markedRequests": markedRequests, "changeEvents": changeEvents,
      "rejectedChanges": rejectedChanges, "lastRejection": lastRejection]
  }
  func noteInputChange() { if diagnosticsEnabled { changeEvents = min(1_000_000, changeEvents + 1) } }
  func noteInputRejection(_ reason: String) {
    if diagnosticsEnabled { rejectedChanges = min(1_000_000, rejectedChanges + 1); lastRejection = reason }
  }

  var isCurrentTarget: Bool {
    guard let model else { return false }
    return acceptingInput && model.keyboardVisible && !model.keyboardSecret
      && model.textEntryTarget == target && model.keyboardSession == sessionID && model.systemTextView === self
  }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    // SwiftUI can attach the editor after makeNSView's next run-loop turn.
    // Request the insertion point when attachment actually happens, rather
    // than making a single attempt while window is still nil.
    guard let attachedWindow = window else { return }
    DispatchQueue.main.async { [weak self, weak attachedWindow] in
      guard let self, let attachedWindow, self.window === attachedWindow, self.isCurrentTarget else { return }
      attachedWindow.makeFirstResponder(self)
    }
  }
  override func insertText(_ value: Any, replacementRange: NSRange) {
    if diagnosticsEnabled { insertRequests = min(1_000_000, insertRequests + 1) }
    guard isCurrentTarget else { return }
    super.insertText(value, replacementRange: replacementRange)
  }
  override func setMarkedText(_ value: Any, selectedRange: NSRange, replacementRange: NSRange) {
    if diagnosticsEnabled { markedRequests = min(1_000_000, markedRequests + 1) }
    guard isCurrentTarget else { noteInputRejection("inactive-target"); return }
    super.setMarkedText(value, selectedRange: selectedRange, replacementRange: replacementRange)
  }
  func finishInput(commit: Bool) {
    // Only stop dictation owned by this current foreground text client. A late
    // dismantle of an old view must not stop another editor's session.
    let ownsForegroundInput = isCurrentTarget && NSApp.isActive && window?.isKeyWindow == true
      && window?.firstResponder === self && (NSTextInputContext.current?.client as AnyObject?) === self
    if commit && hasMarkedText() {
      unmarkText()
      if isCurrentTarget { model?.acceptSystemText(string) }
    } else if !commit { inputContext?.discardMarkedText() }
    if ownsForegroundInput, let menu = NSApp.mainMenu {
      SystemDictationCommand.refresh(menu)
      if let item = SystemDictationCommand.stopItem(in: menu), let action = item.action {
        _ = NSApp.sendAction(action, to: item.target, from: item)
      }
    }
    acceptingInput = false
    if window?.firstResponder === self { window?.makeFirstResponder(nil) }
  }
}

struct SystemTextInput: NSViewRepresentable {
  @ObservedObject var model: AppModel
  @Environment(\.colorScheme) private var colorScheme
  final class Coordinator: NSObject, NSTextViewDelegate {
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
      guard let view = textView as? MTVSystemTextView else { return false }
      guard view.isCurrentTarget else { view.noteInputRejection("inactive-target"); return false }
      let current = view.string as NSString
      guard affectedCharRange.location != NSNotFound, affectedCharRange.location <= current.length,
        affectedCharRange.length <= current.length - affectedCharRange.location else { view.noteInputRejection("invalid-range"); return false }
      let fits = current.replacingCharacters(in: affectedCharRange, with: replacementString ?? "").utf8.count <= 8192
      if !fits { view.noteInputRejection("oversize") }; return fits
    }
    func textDidChange(_ notification: Notification) {
      (notification.object as? MTVSystemTextView)?.noteInputChange()
      guard let view = notification.object as? MTVSystemTextView,
        !view.updatingFromModel, view.isCurrentTarget else { return }
      view.model?.acceptSystemText(view.string)
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> NSScrollView {
    let scroll = NSScrollView()
    scroll.drawsBackground = false; scroll.borderType = .noBorder
    scroll.hasHorizontalScroller = false; scroll.hasVerticalScroller = false
    let view = MTVSystemTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 38))
    view.model = model; view.target = model.textEntryTarget; view.sessionID = model.keyboardSession
    view.identifier = NSUserInterfaceItemIdentifier("MTVSystemTextInput")
    view.delegate = context.coordinator
    view.isRichText = false; view.importsGraphics = false; view.allowsUndo = false
    view.isEditable = true; view.isSelectable = true; view.drawsBackground = false
    view.font = .systemFont(ofSize: 25); view.textColor = .labelColor
    view.insertionPointColor = .labelColor
    view.textContainerInset = .zero
    view.isVerticallyResizable = false; view.isHorizontallyResizable = true
    view.minSize = NSSize(width: 200, height: 38)
    view.maxSize = NSSize(width: 100_000, height: 38)
    view.textContainer?.containerSize = NSSize(width: 100_000, height: 38)
    view.textContainer?.widthTracksTextView = false
    view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    view.isAutomaticSpellingCorrectionEnabled = false
    view.isAutomaticQuoteSubstitutionEnabled = false
    view.isAutomaticDashSubstitutionEnabled = false
    view.isAutomaticTextReplacementEnabled = false
    view.string = model.inputText
    view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
    scroll.documentView = view
    model.systemTextView = view
    return scroll
  }
  func updateNSView(_ scroll: NSScrollView, context: Context) {
    guard let view = scroll.documentView as? MTVSystemTextView else { return }
    view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    guard view.isCurrentTarget, !view.hasMarkedText(), view.string != model.inputText else { return }
    view.updatingFromModel = true
    view.string = model.inputText
    view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
    view.scrollRangeToVisible(view.selectedRange())
    view.updatingFromModel = false
  }
  static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
    guard let view = scroll.documentView as? MTVSystemTextView else { return }
    view.finishInput(commit: false)
    if view.model?.systemTextView === view { view.model?.systemTextView = nil }
    view.delegate = nil; view.model = nil
  }
}

extension AppModel {
  var systemDictationReadiness: String {
    guard keyboardVisible else { return "input-not-open" }
    guard !keyboardSecret else { return "secret-input-not-supported" }
    guard let view = systemTextView, view.isCurrentTarget, view.inputContext != nil else { return "native-input-not-ready" }
    guard let window = view.window, NSApp.isActive, NSApp.keyWindow === window else { return "input-window-not-active" }
    guard let menu = NSApp.mainMenu else { return "system-start-command-unavailable" }
    SystemDictationCommand.refresh(menu)
    guard SystemDictationCommand.startItem(in: menu) != nil else { return "system-start-command-unavailable" }
    return "start-command-available"
  }
  /// Use the system's own existing menu command; never emulate microphone keys
  /// or call private dictation services. It runs only after a user selects 听写.
  func requestSystemDictation() {
    guard keyboardVisible, !keyboardSecret, let view = systemTextView, view.isCurrentTarget else {
      lastDictationRequest = "nonsecret-input-required"; return
    }
    guard let window = view.window, NSApp.isActive, NSApp.keyWindow === window else {
      lastDictationRequest = "input-window-not-active"
      notice = "请先回到 MacTV 的输入框，再开始听写。"; return
    }
    guard view.window?.makeFirstResponder(view) == true else { lastDictationRequest = "native-input-not-ready"; return }
    if CommandLine.arguments.contains("--ui-smoke"), !CommandLine.arguments.contains("--system-dictation-only") {
      lastDictationRequest = "fixture-system-start-disabled"; return
    }
    if let menu = NSApp.mainMenu {
      SystemDictationCommand.refresh(menu)
      if let item = SystemDictationCommand.startItem(in: menu), let action = item.action,
        NSApp.sendAction(action, to: item.target, from: item) {
        lastDictationRequest = "system-start-dispatched"; return
      }
    }
    lastDictationRequest = "system-start-command-unavailable"
    // Some system configurations do not offer dictation until it is enabled.
    // Keep the current draft and open the official keyboard settings page.
    notice = "请在系统设置的“键盘”中开启听写，再返回这里输入。"
    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
      NSWorkspace.shared.open(url)
    }
  }
}

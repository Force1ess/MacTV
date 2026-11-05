import AppKit
import MTVCore

extension UISmoke {
  static func systemTextInputSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    let search = model.search, address = model.smb.address, password = model.smb.password
    checks["initialInputModeFollowsInterfaceLanguage"] = model.chinese == (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh")
    defer {
      if model.keyboardVisible { model.finishTextEntry(commit: false) }
      model.search = search; model.smb.address = address; model.smb.password = password
      model.notice = nil; model.navigate(.home)
    }
    func waitEditor() async {
      for _ in 0..<100 {
        if let view = model.systemTextView, view.isCurrentTarget, view.window != nil { break }
        try? await Task.sleep(for: .milliseconds(30))
      }
      await settle()
    }
    model.navigate(.library); model.search = ""; model.showKeyboard()
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    await waitEditor()
    guard let view = model.systemTextView else { return ["systemTextInputActuallyMounted": false] }
    checks["systemTextInputActuallyMounted"] = view.window === window && view.inputContext != nil
    checks["systemTextInputHasRealInsertionPoint"] = view.selectedRange().location == 0
      && window.firstResponder === view
    let rect = view.firstRect(forCharacterRange: view.selectedRange(), actualRange: nil)
    checks["systemTextInputHasOnscreenCaretGeometry"] = rect.height > 0 && rect.minX.isFinite && rect.minY.isFinite
    func pressVoiceKey() async -> Bool {
      guard let binding=model.dictationKey.trigger else { return false }
      let type:NSEvent.EventType=VoiceKeyBinding.modifierKeys[binding.keyCode] == nil ? .keyDown:.flagsChanged
      guard let event=NSEvent.keyEvent(with:type,location:.zero,modifierFlags:NSEvent.ModifierFlags(rawValue:binding.modifiers),
        timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,
        characters:"",charactersIgnoringModifiers:"",isARepeat:false,keyCode:binding.keyCode) else { return false }
      NSApp.postEvent(event,atStart:false); await settle(); return true
    }
    model.lastDictationRequest="idle"
    let voicePosted=await pressVoiceKey()
    checks["voiceKeyTargetsDictationInsideTextEntry"] = voicePosted && model.lastDictationRequest=="fixture-system-start-disabled"
    view.insertText(NSAttributedString(string: "百年孤独🎬"), replacementRange: NSRange(location: NSNotFound, length: 0))
    await settle()
    checks["systemTextInputReceivesAttributedUnicode"] = model.search == "百年孤独🎬" && view.string == model.search
    view.insertText("三体", replacementRange: NSRange(location: 0, length: 4))
    await settle()
    checks["systemTextInputUsesUTF16ReplacementRanges"] = model.search == "三体🎬"
    view.insertText("\n剧集", replacementRange: NSRange(location: NSNotFound, length: 0))
    await settle()
    checks["systemTextInputNormalizesMultilineSearch"] = model.search == "三体🎬 剧集" && view.string == model.search
    let before = model.search
    view.insertText(String(repeating: "x", count: 8193), replacementRange: NSRange(location: 0, length: (view.string as NSString).length))
    await settle()
    checks["systemTextInputRejectsOversizeReplacement"] = model.search == before && view.string == before
    if !model.chinese { model.pressKey("中/英") }
    model.pressKey("N"); await settle()
    view.insertText("推荐", replacementRange: NSRange(location: NSNotFound, length: 0))
    await settle()
    checks["systemInsertionClearsSeparatePinyinComposition"] = model.composing.isEmpty && model.search == before + "推荐"
    let nativeText = model.search
    model.keyboardFocus.select(row: 0, column: 0)
    window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); await settle()
    model.smokeKeyRoute = [:]
    let beforeKeyActive = NSApp.isActive
    if let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window.windowNumber, context: nil, characters: "\u{F703}", charactersIgnoringModifiers: "\u{F703}", isARepeat: false, keyCode: 124) {
      NSApp.postEvent(event, atStart: false); await settle()
      checks["nativeRightKeyStillMovesTVKeyboardFocus"] = NSApp.isActive && model.keyboardFocus.column == 1 && model.search == nativeText
    } else { checks["nativeRightKeyStillMovesTVKeyboardFocus"] = false }
    let keyEvidence: [String: Any] = ["activeBefore": beforeKeyActive, "activeAfter": NSApp.isActive,
      "column": model.keyboardFocus.column, "row": model.keyboardFocus.row, "textUnchanged": model.search == nativeText,
      "route": model.smokeKeyRoute, "firstResponder": window.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"]
    if let data = try? JSONSerialization.data(withJSONObject: keyEvidence, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("native-key-route.json"))
    }
    checks["dictationKeyIsRemoteReachableAndDoneRemainsLast"] = model.keyboardRows.last?.contains("听写") == true && model.keyboardRows.last?.last == "完成"
    capture(window, to: output.appendingPathComponent("system-text-input.png"))
    let session = model.keyboardSession
    model.finishTextEntry(commit: false); model.showKeyboard()
    let retiredText = view.string
    view.insertText("LATE", replacementRange: NSRange(location: NSNotFound, length: 0))
    view.setMarkedText("LATE MARKED", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    checks["dismissedInputRejectsLateMarkedText"] = view.string == retiredText && !view.hasMarkedText()
    checks["dismissedInputCannotWriteIntoQuickReopen"] = model.search == nativeText && model.keyboardSession != session
    await waitEditor()
    guard let second = model.systemTextView else { checks["reopenedNativeEditorExists"] = false; return checks }
    checks["reopenedEditorHasFreshTarget"] = second !== view && second.isCurrentTarget
    second.setMarkedText("听写草稿", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
    checks["nativeMarkedTextHasValidSelection"] = second.hasMarkedText() && second.markedRange().location != NSNotFound
      && second.selectedRange().location != NSNotFound
    model.pressKey("完成"); await settle()
    checks["doneCommitsNativeMarkedTextBeforeClosing"] = !model.keyboardVisible && model.search.contains("听写草稿")
    model.smb.address = "original.invalid/Movies"; model.showSMBTextEntry(.address)
    await waitEditor()
    guard let draft = model.systemTextView else { checks["serverDraftNativeEditorExists"] = false; return checks }
    draft.insertText("draft.invalid/Films", replacementRange: NSRange(location: 0, length: (draft.string as NSString).length))
    checks["systemInputDoesNotCommitServerDraftEarly"] = model.smb.address == "original.invalid/Movies" && model.inputText == "draft.invalid/Films"
    model.handle(.back); await settle()
    checks["backCancelsNativeServerDraft"] = !model.keyboardVisible && model.smb.address == "original.invalid/Movies"
    model.smb.password = "SECRET_FIXTURE_ONLY"; model.showSMBTextEntry(.password)
    await settle()
    let secret = model.inputText
    let beforeSecretDictation=model.lastDictationRequest
    _ = await pressVoiceKey()
    checks["secretVoiceKeyDoesNotStartDictation"] = model.lastDictationRequest==beforeSecretDictation && model.inputText==secret
    draft.insertText("LEAK", replacementRange: NSRange(location: NSNotFound, length: 0))
    model.pressKey("听写")
    checks["passwordNeverMountsDictationTextClient"] = model.systemTextView == nil && model.keyboardSecret
      && model.keyboardRows.last?.contains("听写") == false && model.inputText == secret
    checks["passwordRemainsMasked"] = !model.keyboardDisplayText.contains("SECRET")
    capture(window, to: output.appendingPathComponent("secret-input.png"))
    return checks
  }
}

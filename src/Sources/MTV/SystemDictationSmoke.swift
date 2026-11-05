import AppKit
import AVFoundation
import CoreAudio
import Carbon
import MTVCore

extension UISmoke {
  /// Process/device metadata only. Does not open, tap or record any input.
  private static func runningInputClients(on device: AudioObjectID) -> Set<AudioObjectID>? {
    func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID]? {
      var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
      var bytes: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &bytes) == noErr,
        bytes <= 65536, bytes % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return nil }
      if bytes == 0 { return [] }
      var values = [AudioObjectID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioObjectID>.size)
      guard AudioObjectGetPropertyData(object, &address, 0, nil, &bytes, &values) == noErr else { return nil }
      return Array(values.prefix(Int(bytes) / MemoryLayout<AudioObjectID>.size))
    }
    guard #available(macOS 14.2, *), let processes = objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) else { return nil }
    var clients = Set<AudioObjectID>()
    for process in processes {
      guard let running = AudioOutputHardware.uint(process, kAudioProcessPropertyIsRunningInput),
        let devices = objects(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput) else { return nil }
      if running == 1 && devices.contains(device) { clients.insert(process) }
    }
    return clients
  }
  /// Explicit live test: owned speech -> named virtual device -> macOS
  /// Dictation -> the real MTV text client. No transcript or credentials logged.
  static func systemDictationSmoke(model: AppModel, window: NSWindow) async -> [String: Any] {
    var checks: [String: Bool] = [:]
    var report: [String: Any] = ["scope": "owned-speech-through-system-dictation",
      "physicalRemoteVerified": false, "physicalMicrophoneUsed": false,
      "imagesUsed": false, "systemDictationStartRequested": false]
    let args = CommandLine.arguments
    func argument(_ key: String) -> String? {
      guard let index = args.firstIndex(of: key), index + 1 < args.count else { return nil }
      return args[index + 1]
    }
    func normalized(_ value: String) -> String {
      String(value.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) })
    }
    func wait(_ condition: () -> Bool) async -> Bool {
      for _ in 0..<200 {
        if condition() { return true }
        do { try await Task.sleep(for: .milliseconds(50)) } catch { return false }
      }
      return false
    }
    let originalSearch = model.search
    var audio: AVPlayer?
    var inputView: MTVSystemTextView?
    defer {
      audio?.pause(); audio?.replaceCurrentItem(with: nil)
      if model.keyboardVisible { model.finishTextEntry(commit: false) }
      inputView?.doCommand(by: NSSelectorFromString("cancelOperation:"))
      inputView?.inputContext?.discardMarkedText()
      model.search = originalSearch; model.notice = nil; model.navigate(.home)
    }
    do {
      guard let fixturePath = argument("--dictation-fixture"),
        let uid = argument("--dictation-virtual-input"),
        ["MiRemoteV2ch_UID", "BlackHole2ch_UID"].contains(uid) else {
        checks["explicitOwnedFixtureAndVirtualInputRequired"] = false
        throw MTVError.message("Explicit fixture and virtual input required")
      }
      let fixture = URL(fileURLWithPath: fixturePath)
      let file = try AVAudioFile(forReading: fixture)
      let duration = Double(file.length) / file.fileFormat.sampleRate
      checks["ownedSpeechFixtureIsBoundedAudio"] = duration > 0 && duration <= 10 && file.fileFormat.channelCount <= 2
      guard checks["ownedSpeechFixtureIsBoundedAudio"] == true else { throw MTVError.message("Invalid speech fixture") }
      let system = AudioObjectID(kAudioObjectSystemObject)
      let initialInput = AudioOutputHardware.uint(system, kAudioHardwarePropertyDefaultInputDevice)
      let initialOutput = AudioOutputHardware.uint(system, kAudioHardwarePropertyDefaultOutputDevice)
      guard let device = AudioOutputHardware.devices().first(where: { $0.uid == uid }), initialInput == device.id else {
        checks["explicitVirtualDeviceIsCurrentSystemInput"] = false
        throw MTVError.message("Virtual input is not selected")
      }
      checks["explicitVirtualDeviceIsCurrentSystemInput"] = true
      let source = AVPlayer(url: fixture); source.audioOutputDeviceUniqueID = uid; source.volume = 0.7
      audio = source
      _ = await wait { source.currentItem?.status == .readyToPlay || source.currentItem?.status == .failed }
      checks["ownedAudioReadyOnRequestedVirtualOutput"] = source.currentItem?.status == .readyToPlay && source.audioOutputDeviceUniqueID == uid
      guard checks["ownedAudioReadyOnRequestedVirtualOutput"] == true else { throw MTVError.message("Audio route not ready") }
      model.navigate(.home); model.search = ""; model.showKeyboard()
      window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
      let ready = await wait {
        guard let view = model.systemTextView else { return false }
        return view.isCurrentTarget && view.window === window && NSApp.isActive && window.isKeyWindow && window.firstResponder === view
      }
      checks["foregroundNativeInsertionPointReady"] = ready
      guard ready, let view = model.systemTextView else { throw MTVError.message("Native insertion point not ready") }
      inputView = view
      if let context = NSTextInputContext.current {
        report["nativeContextClientClass"] = String(describing: type(of: context.client))
        report["nativeContextTargetsEditor"] = (context.client as AnyObject) === view
        report["nativeContextMatchesEditorContext"] = context === view.inputContext
      } else { report["nativeContextTargetsEditor"] = false; report["nativeContextClientClass"] = "none" }
      report["secureInputBeforeStart"] = IsSecureEventInputEnabled()
      let initialClients = runningInputClients(on: device.id)
      report["inputActivityMetadataAvailable"] = initialClients != nil
      if let initialClients { report["inputClientsBeforeStart"] = initialClients.count }
      checks["nativeInputStartsEmpty"] = view.string.isEmpty && model.inputText.isEmpty
      report["readinessBeforeStart"] = model.systemDictationReadiness
      guard checks["nativeInputStartsEmpty"] == true else { throw MTVError.message("Input was not empty") }
      let started = ProcessInfo.processInfo.systemUptime
      let startMethod = argument("--dictation-start-method") ?? "native-key"
      report["startMethod"] = startMethod
      if startMethod == "direct" { model.pressKey("听写") }
      else {
        guard startMethod == "native-key", let column = model.keyboardRows.last?.firstIndex(of: "听写"),
          let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else { throw MTVError.message("Dictation key not available") }
        model.keyboardFocus.select(row: model.keyboardRows.count - 1, column: column)
        NSApp.postEvent(event, atStart: false)
        _ = await wait { model.lastDictationRequest != "idle" }
      }
      checks["systemDictationStartDispatched"] = model.lastDictationRequest == "system-start-dispatched"
      guard checks["systemDictationStartDispatched"] == true else { throw MTVError.message("System command unavailable") }
      report["systemDictationStartRequested"] = true
      report["dispatchLatencyMS"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
      let audioStart = argument("--dictation-audio-start") ?? "immediate"
      guard ["immediate", "input-ready"].contains(audioStart) else { throw MTVError.message("Unknown audio start condition") }
      report["audioStartCondition"] = audioStart
      var firstNewInputClientMS: Double?
      if audioStart == "input-ready" {
        let ready = await wait {
          guard let initialClients, let clients = runningInputClients(on: device.id) else { return false }
          return !clients.subtracting(initialClients).isEmpty
        }
        checks["inputStartedBeforeOwnedAudio"] = ready
        guard ready else { throw MTVError.message("System did not open the selected input") }
        firstNewInputClientMS = (ProcessInfo.processInfo.systemUptime - started) * 1000
      }
      report["ownedAudioStartMS"] = (ProcessInfo.processInfo.systemUptime - started) * 1000
      source.play()
      let expected = "这是语音输入测试"
      var firstTextMS: Double?
      var matchedSince: Double?
      var matched = false
      var firstForegroundLossMS: Double?
      var peakInputClients = initialClients?.count ?? 0
      for _ in 0..<800 {
        let now = ProcessInfo.processInfo.systemUptime
        if let clients = runningInputClients(on: device.id) {
          peakInputClients = max(peakInputClients, clients.count)
          if let initialClients, !clients.subtracting(initialClients).isEmpty, firstNewInputClientMS == nil {
            firstNewInputClientMS = (now - started) * 1000
          }
        }
        if (!NSApp.isActive || !window.isKeyWindow), firstForegroundLossMS == nil { firstForegroundLossMS = (now - started) * 1000 }
        let text = normalized(view.string)
        if !text.isEmpty, firstTextMS == nil { firstTextMS = (now - started) * 1000 }
        if text == expected, source.currentTime().seconds >= duration - 0.05 {
          if matchedSince == nil { matchedSince = now }
          if now - matchedSince! >= 0.5 { matched = true; break }
        } else { matchedSince = nil }
        try await Task.sleep(for: .milliseconds(50))
      }
      if let firstTextMS { report["firstTextMS"] = firstTextMS }
      if let firstForegroundLossMS { report["firstForegroundLossMS"] = firstForegroundLossMS }
      if let firstNewInputClientMS { report["firstNewInputClientMS"] = firstNewInputClientMS }
      report["peakInputClients"] = peakInputClients
      report["foregroundAtCompletion"] = NSApp.isActive && window.isKeyWindow
      report["secureInputAtCompletion"] = IsSecureEventInputEnabled()
      report["fixtureDuration"] = duration
      let deliveredText = normalized(view.string)
      report["transcribedCharacterCount"] = deliveredText.count
      report["expectedFragmentsRecognized"] = ["这是", "语音", "输入", "测试"].map { deliveredText.contains($0) }
      // Dictation may deliver the complete phrase as marked text and commit it
      // only when Done ends the input session. insertText alone is not the
      // NSTextInputClient contract: retain both native delivery paths.
      let nativeEvents = view.nativeInputEvents
      let nativeDelivered = !deliveredText.isEmpty
        && ((nativeEvents["insertRequests"] as? Int ?? 0) > 0
          || (nativeEvents["markedRequests"] as? Int ?? 0) > 0)
      report["nativeSpeechDeliveryVerified"] = nativeDelivered
      report["markedTextBeforeDone"] = view.hasMarkedText()
      report["nativeInputEvents"] = view.nativeInputEvents
      if let menu = NSApp.mainMenu {
        report["dictationCommands"] = SystemDictationCommand.entries(in: menu).map {
          ["selector": $0.selector, "targetClass": $0.targetClass, "resolvedTargetClass": $0.resolvedTargetClass,
            "responderTargetClass": $0.responderTargetClass] }
      }
      checks["ownedAudioActuallyAdvanced"] = source.currentTime().seconds > 0.5
      checks["actualTextReceivedThroughNativeInputClient"] = nativeDelivered
      checks["systemTranscribedExpectedOwnedPhrase"] = matched
      model.pressKey("完成")
      checks["donePreservesActualNativeTranscription"] = !deliveredText.isEmpty && !model.keyboardVisible && normalized(model.search) == deliveredText
      checks["doneCommitsTranscribedSearch"] = !model.keyboardVisible && normalized(model.search) == expected
      checks["completedInputRejectsLateNativeWrites"] = !view.isCurrentTarget
      if let initialClients {
        checks["closingInputReleasesNewAudioClients"] = await wait {
          guard let clients = runningInputClients(on: device.id) else { return false }
          return clients.subtracting(initialClients).isEmpty
        }
      } else { checks["closingInputReleasesNewAudioClients"] = false }
      checks["defaultAudioDevicesUnchanged"] = initialInput == AudioOutputHardware.uint(system, kAudioHardwarePropertyDefaultInputDevice)
        && initialOutput == AudioOutputHardware.uint(system, kAudioHardwarePropertyDefaultOutputDevice)
    } catch {
      report["errorDomain"] = (error as NSError).domain
      report["errorCode"] = (error as NSError).code
    }
    report["checks"] = checks
    let verified = checks["systemTranscribedExpectedOwnedPhrase"] == true && checks["doneCommitsTranscribedSearch"] == true
    report["passed"] = verified && !checks.isEmpty && checks.values.allSatisfy { $0 }
    report["macOSAudioTranscriptionVerified"] = verified
    return report
  }
}

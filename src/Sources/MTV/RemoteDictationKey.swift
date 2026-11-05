import AppKit
import MTVCore

@MainActor final class RemoteDictationKey {
  let trigger: VoiceKeyBinding?
  init(defaults: UserDefaults = .standard) {
    if let data = defaults.data(forKey: "mactv.voice.remote-key.v1"),
      let saved = try? JSONDecoder().decode(VoiceKeyBinding.self, from: data), saved.isEligible {
      trigger = saved
    } else { trigger = Self.companionBinding() }
  }
  private static func companionBinding() -> VoiceKeyBinding? {
    let bundle = "com.hd838a.RemoteMic"
    guard NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundle) != nil else { return nil }
    let mode = CFPreferencesCopyAppValue("voiceKeyMode" as CFString,bundle as CFString) as? String ?? "fn"
    let options: [String:(UInt16,NSEvent.ModifierFlags,String)] = ["fn":(63,.function,"Fn"),
      "left_command":(55,.command,"Left ⌘"),"right_command":(54,.command,"Right ⌘"),
      "left_option":(58,.option,"Left ⌥"),"right_option":(61,.option,"Right ⌥")]
    guard let (key,flags,label) = options[mode] else { return nil }
    return VoiceKeyBinding(keyCode:key,modifiers:flags,label:label)
  }
  func consume(_ event: NSEvent, onTrigger: () -> Void) -> Bool {
    guard event.type == .keyDown || event.type == .flagsChanged,
      trigger?.matches(event) == true else { return false }
    if event.type == .flagsChanged {
      guard let expected = VoiceKeyBinding.modifierKeys[event.keyCode],
        event.modifierFlags.intersection([.command,.control,.option,.shift,.function]) == expected else { return false }
    }
    if event.type != .keyDown || !event.isARepeat { onTrigger() }
    return true
  }
}

import AppKit
import Testing
@testable import MTVCore

struct VoiceKeyBindingTests {
  @Test func remoteVoiceCanUseF5OrEitherStandaloneCommandAndOptionKey() throws {
    #expect(VoiceKeyBinding(keyCode:96,modifiers:[],label:"F5").isEligible)
    for (key, flags) in [(UInt16(54),NSEvent.ModifierFlags.command),(55,.command),(58,.option),(61,.option),(63,.function)] {
      let binding = VoiceKeyBinding(keyCode:key,modifiers:flags,label:"remote")
      #expect(binding.isEligible)
      let raw = try #require(CGEvent(keyboardEventSource:nil,virtualKey:key,keyDown:true))
      raw.type = .flagsChanged; raw.flags = CGEventFlags(rawValue:UInt64(flags.rawValue))
      let down = try #require(NSEvent(cgEvent:raw)); #expect(binding.matches(down))
      raw.flags = []; let up = try #require(NSEvent(cgEvent:raw)); #expect(!binding.matches(up))
    }
  }
  @Test func preservesNavigationAndTyping() {
    for key: UInt16 in [36, 48, 51, 53, 76, 117, 123, 124, 125, 126] {
      #expect(!VoiceKeyBinding(keyCode: key, modifiers: [.command], label: "reserved").isEligible)
    }
    #expect(!VoiceKeyBinding(keyCode: 9, modifiers: [], label: "v").isEligible)
    #expect(!VoiceKeyBinding(keyCode: 9, modifiers: [.shift], label: "V").isEligible)
    #expect(VoiceKeyBinding(keyCode: 9, modifiers: [.command, .shift], label: "⌘⇧V").isEligible)
    #expect(VoiceKeyBinding(keyCode: 80, modifiers: [], label: "F19").isEligible)
    #expect(VoiceKeyBinding(keyCode: 63, modifiers: [.function], label: "Fn").isEligible)
    #expect(!VoiceKeyBinding(keyCode: 63, modifiers: [], label: "Fn").isEligible)
    #expect(VoiceKeyBinding(keyCode: 80, modifiers: [.function], label: "F19").isEligible)
  }
  @Test func ignoresLabelsForLoopPrevention() throws {
    let source = VoiceKeyBinding(keyCode: 80, modifiers: [], label: "Remote")
    let target = VoiceKeyBinding(keyCode: 80, modifiers: [], label: "F19")
    #expect(source.sameChord(as: target))
    let restored = try JSONDecoder().decode(VoiceKeyBinding.self, from: JSONEncoder().encode(source))
    #expect(restored == source)
  }
}

import AppKit

/// Public keyboard events only; no dependency on another app's private settings.
public struct VoiceKeyBinding: Codable, Equatable, Sendable {
  public static let modifierKeys: [UInt16:NSEvent.ModifierFlags] = [63:.function,54:.command,55:.command,58:.option,61:.option,56:.shift,60:.shift,59:.control,62:.control]
  public static let functionKeys: Set<UInt16> = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
  public let keyCode: UInt16
  public let modifiers: UInt
  public let label: String
  public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, label: String) {
    self.keyCode = keyCode
    let relevant: NSEvent.ModifierFlags = keyCode == 63 ? [.command, .control, .option, .shift, .function] : [.command, .control, .option, .shift]
    self.modifiers = modifiers.intersection(relevant).rawValue
    self.label = String(label.prefix(64))
  }
  public var isEligible: Bool {
    if let expected = Self.modifierKeys[keyCode] { return modifiers == expected.rawValue }
    // Preserve ordinary typing, arrows, Enter and all return keys.
    guard keyCode < 128, ![36, 48, 51, 53, 76, 117, 123, 124, 125, 126].contains(keyCode) else { return false }
    let flags = NSEvent.ModifierFlags(rawValue: modifiers)
    let allowed: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
    guard flags.subtracting(allowed).isEmpty else { return false }
    return !flags.intersection([.command, .control, .option]).isEmpty
      || Self.functionKeys.contains(keyCode)
  }
  public func matches(_ event: NSEvent) -> Bool {
    if let expected = Self.modifierKeys[keyCode] {
      return event.type == .flagsChanged && event.keyCode == keyCode
        && event.modifierFlags.intersection([.command, .control, .option, .shift, .function]) == expected
    }
    return event.type == .keyDown && keyCode == event.keyCode
      && modifiers == event.modifierFlags.intersection([.command, .control, .option, .shift]).rawValue
  }
  public func sameChord(as other: Self) -> Bool { keyCode == other.keyCode && modifiers == other.modifiers }
}

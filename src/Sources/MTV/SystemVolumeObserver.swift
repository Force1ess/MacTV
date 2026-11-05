import CoreAudio
import Foundation

@MainActor final class SystemVolumeObserver {
  struct State: Sendable { let volume: Float?; let muted: Bool }
  private final class Listeners {
    var values: [(AudioObjectID, AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    func clear() {
      for (object, original, block) in values {
        var address = original
        AudioObjectRemovePropertyListenerBlock(object, &address, .main, block)
      }
      values.removeAll()
    }
    deinit { clear() }
  }
  private let system = Listeners(), device = Listeners()
  private var selected: AudioDeviceID = 0
  private let changed: (State) -> Void
  init(changed: @escaping (State) -> Void) {
    self.changed = changed
    listen(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice,
      scope: kAudioObjectPropertyScopeGlobal, element: 0, into: system)
    refresh()
  }
  private func listen(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope, element: AudioObjectPropertyElement, into listeners: Listeners) {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    guard AudioObjectHasProperty(object, &address) else { return }
    let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      Task { @MainActor in self?.refresh() }
    }
    if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
      listeners.values.append((object, address, block))
    }
  }
  private func refresh() {
    let current = AudioOutputHardware.uint(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice) ?? 0
    if current != selected {
      device.clear(); selected = current
      for element in 0...2 {
        for property in [kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyMute] {
          listen(current, selector: property, scope: kAudioDevicePropertyScopeOutput,
            element: AudioObjectPropertyElement(element), into: device)
        }
      }
    }
    changed(Self.read(current))
  }
  static func read(_ object: AudioDeviceID) -> State {
    var volumes: [Float] = [], muted = false
    for element in 0...2 {
      var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput, mElement: AudioObjectPropertyElement(element))
      var scalar: Float = 0, size = UInt32(MemoryLayout<Float>.size)
      if AudioObjectGetPropertyData(object, &address, 0, nil, &size, &scalar) == noErr, scalar.isFinite {
        volumes.append(min(1, max(0, scalar)))
        if element == 0 { break }
      }
    }
    for element in 0...2 {
      var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
        mScope: kAudioDevicePropertyScopeOutput, mElement: AudioObjectPropertyElement(element))
      var value: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
      if AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr {
        muted = value != 0; break
      }
    }
    return State(volume: volumes.isEmpty ? nil : volumes.reduce(0,+) / Float(volumes.count), muted: muted)
  }
}

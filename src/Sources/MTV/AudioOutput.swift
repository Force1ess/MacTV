import CoreAudio
import Foundation
import MTVCore
import SwiftUI

struct AudioOutputDevice: Identifiable, Sendable {
  let id: AudioDeviceID
  let uid: String
  let name: String
  let hdmi: Bool
  let systemDefault: Bool
  let configuredChannels: Int?
}
enum AudioOutputHardware {
  static let preferenceKey = "mtv.audio.output"
  static var audibleTest: Bool {
    CommandLine.arguments.contains("--ui-smoke") && CommandLine.arguments.contains("--audio-output-only")
      && CommandLine.arguments.contains("--test-audible-output")
  }
  static var preference: String {
    if CommandLine.arguments.contains("--ui-smoke") {
      if audibleTest { return "tv" }
      if CommandLine.arguments.contains("--playback-benchmark-only") {
        return (try? PlaybackBenchmarkAudioOutput.validated(arguments: CommandLine.arguments))?.rawValue ?? "invalid-benchmark-output"
      }
      return "system"
    }
    return UserDefaults.standard.string(forKey: preferenceKey) ?? "system"
  }
  private static func address(_ selector: AudioObjectPropertySelector, output: Bool = false) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: output ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
  }
  static func uint(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
    var property = address(selector), size = UInt32(MemoryLayout<UInt32>.size), value: UInt32 = 0
    return AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr ? value : nil
  }
  private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var property = address(selector), size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    var value: Unmanaged<CFString>?
    guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
  }
  static func devices() -> [AudioOutputDevice] {
    var property = address(kAudioHardwarePropertyDevices), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size) == noErr,
      size > 0, size <= 1024 else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &property, 0, nil, &size, &ids) == noErr else { return [] }
    let defaultID = uint(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice)
    return ids.compactMap { id in
      var streams = address(kAudioDevicePropertyStreams, output: true), bytes: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &bytes) == noErr, bytes > 0,
        uint(id, kAudioDevicePropertyDeviceIsAlive) == 1,
        let uid = string(id, kAudioDevicePropertyDeviceUID), let name = string(id, kAudioObjectPropertyName) else { return nil }
      return AudioOutputDevice(id: id, uid: uid, name: name,
        hdmi: uint(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeHDMI,
        systemDefault: defaultID == id, configuredChannels: configuredChannels(id))
    }
  }
  private static func configuredChannels(_ device: AudioDeviceID) -> Int? {
    var property = address(kAudioDevicePropertyStreamConfiguration, output: true), bytes: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &property, 0, nil, &bytes) == noErr,
      bytes >= UInt32(MemoryLayout<AudioBufferList>.size), bytes <= 65536 else { return nil }
    let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { memory.deallocate() }
    guard AudioObjectGetPropertyData(device, &property, 0, nil, &bytes, memory) == noErr else { return nil }
    let list = memory.assumingMemoryBound(to: AudioBufferList.self)
    let count = Int(list.pointee.mNumberBuffers)
    guard (1...64).contains(count), Int(bytes) >= MemoryLayout<AudioBufferList>.size + (count - 1) * MemoryLayout<AudioBuffer>.stride else { return nil }
    let channels = UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    return (1...64).contains(channels) ? channels : nil
  }
  static func resolve(_ choice: String? = nil) throws -> AudioOutputDevice? {
    let choice = choice ?? preference, available = devices()
    if choice == "system" { return nil }
    if choice == "tv" {
      let televisions = available.filter(\.hdmi)
      guard televisions.count <= 1 else { throw MTVError.message("检测到多个HDMI输出，请在设置的声音输出中选择电视") }
      return televisions.first
    }
    guard choice.hasPrefix("device:"), let device = available.first(where: { "device:" + $0.uid == choice }) else {
      throw MTVError.message("所选声音设备未连接，请在设置的声音输出中重新选择")
    }
    return device
  }
  static func needsApplicationVolume() -> Bool {
    guard let device = (try? resolve()) ?? devices().first(where: \.systemDefault) else { return false }
    if !device.systemDefault { return true }
    for element in 0...2 {
      var property = address(kAudioDevicePropertyVolumeScalar, output: true)
      property.mElement = AudioObjectPropertyElement(element)
      var settable: DarwinBoolean = false
      if AudioObjectIsPropertySettable(device.id, &property, &settable) == noErr, settable.boolValue { return false }
    }
    return true
  }
  /// Metadata only: observe this process's running output and device list.
  /// Does not install a tap, open a device or inspect another app's audio.
  static func processUsesOutput(_ device: AudioDeviceID, pid: UInt32) -> Bool? {
    guard #available(macOS 14.2, *) else { return nil }
    func objects(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector,
      scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID]? {
      var property = address(selector); property.mScope = scope
      var bytes: UInt32 = 0
      guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &bytes) == noErr,
        bytes <= 65536, bytes % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return nil }
      if bytes == 0 { return [] }
      var values = [AudioObjectID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioObjectID>.size)
      guard AudioObjectGetPropertyData(object, &property, 0, nil, &bytes, &values) == noErr else { return nil }
      return Array(values.prefix(Int(bytes) / MemoryLayout<AudioObjectID>.size))
    }
    guard let processes = objects(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList) else { return nil }
    for process in processes where uint(process, kAudioProcessPropertyPID) == pid {
      guard let running = uint(process, kAudioProcessPropertyIsRunningOutput),
        let devices = objects(process, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput) else { return nil }
      if running == 1 && devices.contains(device) { return true }
    }
    return false
  }
}

extension AppModel {
  func presentAudioOutputs() {
    audioOutputDevices = AudioOutputHardware.devices()
    let choices = ["system", "tv"] + audioOutputDevices.map { "device:" + $0.uid }
    audioOutputIndex = choices.firstIndex(of: AudioOutputHardware.preference) ?? 0
    audioOutputVisible = true
  }
  func chooseAudioOutput(_ index: Int) {
    let choices = ["system", "tv"] + audioOutputDevices.map { "device:" + $0.uid }
    guard choices.indices.contains(index) else { return }
    do {
      let selected = try AudioOutputHardware.resolve(choices[index])
      if !CommandLine.arguments.contains("--ui-smoke") { UserDefaults.standard.set(choices[index], forKey: AudioOutputHardware.preferenceKey) }
      player?.audioOutputDeviceUniqueID = selected?.uid
      nativeMedia.setOutput(selected)
      vlcEngine?.setAudioOutput(selected)
      mpvEngine?.setOutput(selected)
      nativeMedia.systemVolumeScale = systemPlaybackGain
      if playbackPresented { setPlaybackVolume(playbackVolume) }
      audioOutputVisible = false
    } catch { notice = error.localizedDescription }
  }
}

struct AudioOutputPanel: View {
  @ObservedObject var model: AppModel
  var body: some View {
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 16) {
        Text("声音输出").font(.system(size: 32, weight: .bold))
        let titles = [L("跟随系统 · 默认"), L("优先使用连接的电视")]
          + model.audioOutputDevices.map { $0.name + ($0.systemDefault ? L(" · 系统默认") : "") }
        ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
          TVButton(selected: model.audioOutputIndex == index,
            action: { model.chooseAudioOutput(index) }, hover: { model.audioOutputIndex = index }) {
            Text(title).font(.system(size: 22)).frame(maxWidth: .infinity, alignment: .leading).padding(18)
          }
        }
      }.padding(36).frame(width: 760).tvPopupSurface(radius: 28)
    }
  }
}

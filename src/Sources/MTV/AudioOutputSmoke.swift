import AVFoundation
import CoreAudio
import Foundation
import MTVCore

extension UISmoke {
  static func audioOutputSmoke(model: AppModel, output: URL) async -> [String: Bool] {
    guard AudioOutputHardware.audibleTest else { return ["hardwareAudioRequiresExplicitQuietAudibleTest": false] }
    let original = model.captureLibrarySource(), previous = model.preferredEngine, oldVolume = model.playbackVolume
    defer { model.stopPlayback(); model.preferredEngine = previous; model.playbackVolume = oldVolume; model.restoreLibrarySource(original); model.navigate(.home) }
    var checks: [String: Bool] = [:], evidence: [String: Any] = [:]
    let systemObject = AudioObjectID(kAudioObjectSystemObject)
    let defaultBefore = AudioOutputHardware.uint(systemObject, kAudioHardwarePropertyDefaultOutputDevice)
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<150 { if condition() { return }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    do {
      guard let hdmi = try AudioOutputHardware.resolve("tv"), hdmi.hdmi else { throw MTVError.message("没有连接HDMI，无法验证电视输出") }
      evidence["deviceName"] = hdmi.name; evidence["coreAudioDeviceID"] = hdmi.id
      evidence["configuredChannels"] = hdmi.configuredChannels ?? 0
      evidence["idleRunning"] = AudioOutputHardware.uint(hdmi.id, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0
      await openSettingWithRemote(.audio, model: model)
      checks["audioOutputSettingsReachableWithRemote"] = model.audioOutputVisible && model.audioOutputDevices.contains(where: { $0.uid == hdmi.uid })
      model.handle(.back)
      checks["audioOutputBackClosesWithoutChangingSelection"] = !model.audioOutputVisible && AudioOutputHardware.preference == "tv"
      let file = SystemAudioWaveSource.ownedFixtureURL
      model.playbackVolume = 0.1
      model.useLocalRoot(file.deletingLastPathComponent())
      await wait { !model.libraryRefreshing }; await model.waitForSourceSave()
      model.preferredEngine = .system
      model.beginPlayback(url: file, item: MediaItem(id: "owned-hardware-system", title: "系统声音输出检查", url: file.absoluteString), fromBeginning: true)
      await wait { (model.player?.currentTime().seconds ?? 0) > 1.5 || model.playbackInterruption != nil }
      var player = model.player
      checks["audioOutputAVPlayerExplicitHDMI"] = player?.audioOutputDeviceUniqueID == hdmi.uid
      checks["audioOutputAVPlayerNotMutedAndQuietVolume"] = player?.isMuted == false && abs((player?.volume ?? 0) - 0.1) < 0.001
      checks["audioOutputAVPlayerAdvancesWithDeviceRunning"] = (player?.currentTime().seconds ?? 0) > 1 && AudioOutputHardware.uint(hdmi.id, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
      evidence["avVolume"] = player?.volume ?? -1
      model.stopPlayback()
      player?.replaceCurrentItem(with: nil); player = nil
      for _ in 0..<40 {
        if AudioOutputHardware.uint(hdmi.id, kAudioDevicePropertyDeviceIsRunningSomewhere) == 0 { break }
        try? await Task.sleep(for: .milliseconds(25))
      }
      evidence["runningBeforeMPV"] = AudioOutputHardware.uint(hdmi.id, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0
      model.preferredEngine = .mpv
      model.beginPlayback(url: file, item: MediaItem(id: "owned-hardware-mpv", title: "通用声音输出检查", url: file.absoluteString), fromBeginning: true)
      await wait { (model.mpvEngine?.latest?.elapsed ?? 0) > 2 || model.notice != nil }
      guard let engine = model.mpvEngine else { throw MTVError.message(model.notice ?? "MPV did not start") }
      var status: [String: String] = [:]
      for property in ["audio-device", "current-ao", "volume", "mute", "audio-pts", "audio-out-params", "audio-codec-name"] {
        status[property] = await engine.diagnostic(property)
      }
      evidence["mpv"] = status
      let processUsesHDMI = AudioOutputHardware.processUsesOutput(hdmi.id, pid: UInt32(ProcessInfo.processInfo.processIdentifier))
      evidence["mpvProcessUsesHDMI"] = processUsesHDMI ?? false
      evidence["processAudioMetadataAvailable"] = processUsesHDMI != nil
      checks["audioOutputMPVRequestsExactHDMIDevice"] = status["audio-device"] == "coreaudio/" + hdmi.uid
      checks["audioOutputMPVActuallyUsesHDMI"] = status["current-ao"] == "coreaudio" && processUsesHDMI == true
      checks["audioOutputMPVUnmutedQuietVolume"] = status["mute"] == "no" && abs((Double(status["volume"] ?? "") ?? -1) - 10) < 0.01
      checks["audioOutputMPVAudioClockAndFormatPresent"] = (Double(status["audio-pts"] ?? "") ?? 0) > 1
        && !(status["audio-out-params"] ?? "").isEmpty && !(status["audio-codec-name"] ?? "").isEmpty
      checks["audioOutputMPVContinuesVideo"] = (engine.latest?.frames ?? 0) > 0 && model.notice == nil
      model.stopPlayback(); await engine.waitUntilStopped()
      checks["audioOutputLeavesSystemDefaultUnchanged"] = defaultBefore == AudioOutputHardware.uint(systemObject, kAudioHardwarePropertyDefaultOutputDevice)
      evidence["systemDefaultDeviceBefore"] = defaultBefore ?? 0
      evidence["systemDefaultDeviceAfter"] = AudioOutputHardware.uint(systemObject, kAudioHardwarePropertyDefaultOutputDevice) ?? 0
      evidence["hardwareAudioSinkReplaced"] = false
      evidence["televisionSpeakerAudibilityVerified"] = false
    } catch { checks["audioOutputHardwareFlowCompleted"] = false; evidence["error"] = error.localizedDescription }
    if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("audio-output-hardware.json"))
    }
    return checks
  }
}

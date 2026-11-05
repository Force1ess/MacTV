import AVFoundation
import AudioToolbox
import Foundation
import MediaToolbox

/// Test-only observation of this player's decoded audio, before its muted output volume.
private final class AudioProbeState: @unchecked Sendable {
  let lock = NSLock()
  var float32 = false
  var frames = 0
  var nonzero = 0
  func format(_ value: AudioStreamBasicDescription) {
    lock.lock(); defer { lock.unlock() }
    float32 = value.mFormatID == kAudioFormatLinearPCM && value.mBitsPerChannel == 32
      && value.mFormatFlags & kAudioFormatFlagIsFloat != 0
  }
  func observe(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames count: Int) {
    guard lock.try() else { return }; defer { lock.unlock() }
    frames += count
    guard float32 else { return }
    for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
      guard let data = buffer.mData else { continue }
      let values = data.assumingMemoryBound(to: Float.self)
      for index in 0..<min(Int(buffer.mDataByteSize) / 4, count * max(1, Int(buffer.mNumberChannels))) {
        if values[index].isFinite && abs(values[index]) > 0.001 { nonzero += 1 }
      }
    }
  }
  func snapshot() -> (frames: Int, nonzero: Int, float32: Bool) {
    lock.lock(); defer { lock.unlock() }; return (frames, nonzero, float32)
  }
}

final class PlaybackAudioProbe {
  private let state = AudioProbeState()
  private let tap: MTAudioProcessingTap
  init() throws {
    guard CommandLine.arguments.contains("--ui-smoke") else { throw CocoaError(.featureUnsupported) }
    let pointer = Unmanaged.passRetained(state).toOpaque()
    var callbacks = MTAudioProcessingTapCallbacks(version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: pointer,
      init: { _, client, storage in storage.pointee = client },
      finalize: { tap in Unmanaged<AudioProbeState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
      prepare: { tap, _, format in Unmanaged<AudioProbeState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().format(format.pointee) },
      unprepare: { _ in },
      process: { tap, requested, _, buffers, produced, flags in
        let status = MTAudioProcessingTapGetSourceAudio(tap, requested, buffers, flags, nil, produced)
        if status == noErr {
          Unmanaged<AudioProbeState>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
            .observe(buffers, frames: produced.pointee)
        } else { produced.pointee = 0 }
      })
    var created: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &created)
    guard status == noErr, let created else { Unmanaged<AudioProbeState>.fromOpaque(pointer).release(); throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    tap = created
  }
  func attach(to item: AVPlayerItem, track: AVAssetTrack) {
    let parameters = AVMutableAudioMixInputParameters(track: track)
    parameters.audioTapProcessor = tap
    let mix = AVMutableAudioMix(); mix.inputParameters = [parameters]; item.audioMix = mix
  }
  var result: (frames: Int, nonzero: Int, float32: Bool) { state.snapshot() }
}

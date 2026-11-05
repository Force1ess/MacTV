import Foundation
import MTVCore
import VLCBridge

/// Test-only virtual six-hour chirp. Never allocates or writes the whole audio.
private final class RF64ChirpSource: LoopbackByteSource, @unchecked Sendable {
  let wave: FloatAudioWave
  let budget: AudioReadBudget
  let mime = "audio/wav", maximumReadBytes = 16384
  var length: Int { wave.length }
  private let lock = NSLock()
  private var maximumOffset = 0
  init() throws {
    wave = try FloatAudioWave(sampleRate: 192000, channels: 1, frames: 192000 * 21600)
    budget = AudioReadBudget(wave: wave, startFrame: 0)
  }
  func readSize(offset: Int, remaining: Int) -> Int {
    let count = min(maximumReadBytes, remaining)
    if offset < wave.header.count { return min(count, wave.header.count - offset) }
    let tail = (offset - wave.header.count + count) % 4
    return count > tail ? count - tail : count
  }
  func read(offset: Int, count: Int, consumer: UUID) async throws -> Data {
    let plan = try wave.readPlan(offset: offset, count: count)
    if plan.frameCount > 0 { try await budget.allow(throughFrame: plan.firstFrame + Int64(plan.frameCount), consumer: consumer) }
    try Task.checkCancellation()
    var pcm = Data(count: plan.frameCount * 4)
    pcm.withUnsafeMutableBytes { bytes in
      for index in 0..<plan.frameCount {
        let t = Double(plan.firstFrame + Int64(index)) / Double(wave.sampleRate)
        let value = Float(0.1 * sin(2 * Double.pi * (220 * t + 0.05 * t * t)))
        bytes.storeBytes(of: value.bitPattern.littleEndian, toByteOffset: index * 4, as: UInt32.self)
      }
    }
    var data = plan.header
    data.append(pcm.subdata(in: plan.leadingPCMBytes..<(plan.leadingPCMBytes + plan.pcmByteCount)))
    record(offset + count)
    return data
  }
  private func record(_ value: Int) { lock.lock(); maximumOffset = max(maximumOffset, value); lock.unlock() }
  var observedMaximumOffset: Int { lock.lock(); defer { lock.unlock() }; return maximumOffset }
  func releaseConsumer(_ consumer: UUID) { Task { await budget.release(consumer) } }
}

private struct RF64AudioObservation: Sendable {
  let state: Int, time: Double, duration: Double
  let frequency: Double?, scheduledDelay: Double?
}
private actor RF64AudioProbe {
  private var handle: OpaquePointer?
  func begin(root: String, url: String) throws {
    var error = [CChar](repeating: 0, count: 2048)
    guard let value = mtv_vlc_create(root, 1, &error, error.count) else { throw MTVError.message(String(cString: error)) }
    handle = value
    guard mtv_vlc_audio_probe_enable(value) == 0, mtv_vlc_play(value, url, nil, 0, 0, 1) == 0 else {
      mtv_vlc_destroy(value); handle = nil; throw MTVError.message("RF64测试播放器未启动")
    }
  }
  func observe() -> RF64AudioObservation? {
    guard let handle else { return nil }
    let stats = mtv_vlc_stats(handle)
    var blocks = [MTVVLCAudioBlock](repeating: MTVVLCAudioBlock(), count: 256)
    var media: Int64 = 0, clock: Int64 = 0, pause: Int64 = 0
    let count = blocks.withUnsafeMutableBufferPointer {
      mtv_vlc_audio_probe_read(handle, $0.baseAddress, 256, &media, &clock, &pause)
    }
    let near = blocks.prefix(Int(count)).filter { $0.rms > 0.005 && $0.frequency_hz > 100 && abs(Double($0.pts_us - clock) / 1e6) < 0.5 }
      .min { abs($0.pts_us - clock) < abs($1.pts_us - clock) }
    return RF64AudioObservation(state: Int(stats.state), time: Double(media) / 1000,
      duration: Double(stats.length_ms) / 1000, frequency: near?.frequency_hz,
      scheduledDelay: near.map { Double($0.pts_us - clock) / 1e6 })
  }
  func seek(_ seconds: Double) { if let handle { mtv_vlc_seek(handle, Int64(seconds * 1000)) } }
  func stop() { if let handle { mtv_vlc_destroy(handle); self.handle = nil } }
}

extension UISmoke {
  static func rf64AudioSmoke(output: URL) async -> [String: Bool] {
    let player = RF64AudioProbe()
    var checks: [String: Bool] = [:], rows: [[String: Any]] = []
    do {
      let source = try RF64ChirpSource(), path = "/" + UUID().uuidString.lowercased() + "/audio.wav"
      let server = LoopbackMediaServer { candidate in
        guard candidate == path else { throw MTVError.message("自建RF64路径未授权") }
        return .generated(source)
      }
      defer { server.cancel(); Task { await source.budget.cancel() } }
      let port = try await server.start(), url = URL(string: "http://127.0.0.1:\(port)\(path)")!
      checks["rf64VirtualLengthReallyExceeds4GiB"] = source.wave.usesRF64 && source.length > Int(UInt32.max) && source.wave.header.count == 94
      try await player.begin(root: VLCPlaybackEngine.root.path, url: url.absoluteString)
      for (index, target) in [0.0, 7200.0, 0.5].enumerated() {
        if index > 0 {
          await source.budget.seek(frame: Int64(target * Double(source.wave.sampleRate)))
          await player.seek(target)
        }
        var observed: RF64AudioObservation?
        for _ in 0..<160 {
          if let current = await player.observe() {
            // Keep the explicit seek budget until the native clock acknowledges
            // its new position; an old transient clock must not deadlock it.
            if current.time >= target && current.time < target + 10 {
              await source.budget.update(frame: Int64((current.time * Double(source.wave.sampleRate)).rounded()))
              observed = current
              if current.state == 3 && current.frequency != nil && current.time >= target + 0.3 { break }
            }
          }
          try? await Task.sleep(for: .milliseconds(50))
        }
        checks["rf64-\(index)-nativeClockAtRequestedPosition"] = observed?.state == 3 && (observed?.time ?? -1) >= target && (observed?.time ?? .infinity) < target + 3
        checks["rf64-\(index)-nativeDurationUses64BitSize"] = abs((observed?.duration ?? -1) - 21600) < 0.1
        if let observed, let frequency = observed.frequency, let delay = observed.scheduledDelay {
          let expected = 220 + 0.1 * (observed.time + delay)
          checks["rf64-\(index)-actualDecodedChirpMatchesPosition"] = abs(frequency - expected) < 0.05
          rows.append(["target": target, "nativeTime": observed.time, "frequencyHz": frequency,
            "expectedHz": expected, "duration": observed.duration])
        } else { checks["rf64-\(index)-actualDecodedChirpMatchesPosition"] = false }
      }
      checks["rf64DecoderActuallyRequestedBytesBeyond4GiB"] = source.observedMaximumOffset > Int(UInt32.max)
      rows.append(["virtualLength": source.length, "maximumObservedByteOffset": source.observedMaximumOffset,
        "wholeAudioFileCreated": false, "physicalAudioOutputVerified": false, "realLongCompressedMediaTested": false])
      server.cancel(); await source.budget.cancel(); await player.stop()
      checks["rf64StopReleasesPendingReads"] = await source.budget.pendingCount == 0
    } catch { checks["rf64AudioFlowCompleted"] = false; rows.append(["error": error.localizedDescription]); await player.stop() }
    if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("rf64-audio.json"))
    }
    return checks
  }
}

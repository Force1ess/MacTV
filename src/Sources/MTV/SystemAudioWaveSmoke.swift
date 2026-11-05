import Foundation
import MTVCore

extension UISmoke {
  static func systemAudioWaveSmoke(output: URL) async -> [String: Bool] {
    var checks: [String: Bool] = [:], evidence: [String: Any] = [:]
    do {
      let source = try await SystemAudioWaveSource.prepareOwnedFixture(start: 11.5)
      defer { source.cancel() }
      let path = "/" + UUID().uuidString.lowercased() + "/audio.wav"
      let server = LoopbackMediaServer { candidate in
        guard candidate == path else { throw MTVError.message("音轨路径未授权") }
        return .generated(source)
      }
      defer { server.cancel() }
      let port = try await server.start(), url = URL(string: "http://127.0.0.1:\(port)\(path)")!
      let config = URLSessionConfiguration.ephemeral
      config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.urlCache = nil
      config.timeoutIntervalForRequest = 5
      let session = URLSession(configuration: config)
      defer { session.invalidateAndCancel() }
      func request(_ offset: Int, _ count: Int) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(offset + count - 1)", forHTTPHeaderField: "Range")
        return request
      }
      let wave = source.wave
      checks["wavePreservesFixtureFormat"] = wave.sampleRate == 48000 && wave.channels == 1 && wave.frames == 2160000
      let (header, response) = try await session.data(for: request(0, wave.header.count))
      checks["waveHeaderThroughExistingOrigin"] = header == wave.header && (response as? HTTPURLResponse)?.statusCode == 206
      let firstChunk = source.readSize(offset: 0, remaining: wave.length)
      let pcmChunk = source.readSize(offset: wave.header.count, remaining: wave.length - wave.header.count)
      let unalignedChunk = source.readSize(offset: wave.header.count + 1, remaining: 100000)
      checks["waveGeneratedChunksPreserveSampleBoundaries"] = firstChunk == wave.header.count && pcmChunk % wave.bytesPerFrame == 0
        && (unalignedChunk + 1) % wave.bytesPerFrame == 0
      let (severalChunks, _) = try await session.data(for: request(0, wave.header.count + 48000 * wave.bytesPerFrame))
      let samples = severalChunks.dropFirst(wave.header.count).withUnsafeBytes { raw in
        (0..<(raw.count / 4)).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
      }
      checks["waveMultiChunkHTTPPayloadHasCompleteFiniteSamples"] = severalChunks.count == wave.header.count + 192000
        && samples.count == 48000 && samples.allSatisfy { $0.isFinite && abs($0) <= 1 }
      var measurements: [[String: Double]] = []
      for (index, target) in [11.5, 23.5, 11.5].enumerated() {
        await source.budget.seek(frame: Int64(target * Double(wave.sampleRate)))
        let offset = wave.header.count + Int(target * Double(wave.sampleRate)) * wave.bytesPerFrame
        let count = 4800 * wave.bytesPerFrame
        let (pcm, result) = try await session.data(for: request(offset, count))
        checks["waveRange-\(index)-statusAndCount"] = pcm.count == count && (result as? HTTPURLResponse)?.statusCode == 206
        let values: [Float] = pcm.withUnsafeBytes { raw in
          (0..<(pcm.count / 4)).map { raw.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
        }
        var positions: [Double] = []
        for i in 1..<values.count where values[i - 1] <= 0 && values[i] > 0 {
          positions.append(Double(i) - Double(values[i]) / Double(values[i] - values[i - 1]))
        }
        let hz = positions.count > 1 ? Double(positions.count - 1) * Double(wave.sampleRate) / (positions.last! - positions.first!) : 0
        checks["waveRange-\(index)-actualDecodedContent"] = values.allSatisfy(\.isFinite) && abs(hz - (400 + 25 * (target + 0.05))) < 2
        measurements.append(["start": target, "frequencyHz": hz])
      }
      let offset = wave.header.count + 11 * wave.sampleRate * wave.bytesPerFrame + 1
      let (unaligned, partial) = try await session.data(for: request(offset, 31))
      checks["waveUnalignedByteRange"] = unaligned.count == 31 && (partial as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range") == "bytes \(offset)-\(offset + 30)/\(wave.length)"
      await source.budget.seek(frame: 6 * Int64(wave.sampleRate))
      let future = request(wave.header.count + 40 * wave.sampleRate * wave.bytesPerFrame, 1024)
      let pending = Task { try await session.data(for: future) }
      for _ in 0..<100 { if await source.budget.pendingCount > 0 { break }; try? await Task.sleep(for: .milliseconds(10)) }
      checks["waveFutureRequestWaitsForPlaybackClock"] = await source.budget.pendingCount == 1
      pending.cancel()
      _ = try? await pending.value
      for _ in 0..<100 { if await source.budget.pendingCount == 0 { break }; try? await Task.sleep(for: .milliseconds(10)) }
      checks["waveClientCancelReleasesPendingRead"] = await source.budget.pendingCount == 0
      let (afterCancel, _) = try await session.data(for: request(0, 4))
      checks["waveClientCancelKeepsOtherConsumersUsable"] = afterCancel == Data("RIFF".utf8)
      source.cancel()
      do {
        _ = try await source.read(offset: wave.header.count, count: 4, consumer: UUID())
        checks["wavePlaybackCancelRejectsNewReads"] = false
      } catch { checks["wavePlaybackCancelRejectsNewReads"] = error is CancellationError }
      let stats = await source.statistics()
      checks["wavePCMReadRemainsBounded"] = (stats["maximumReadFrames"] ?? Int.max) <= 16385
      evidence = ["measurements": measurements, "statistics": stats, "virtualLength": wave.length,
        "nativeVLCPlaybackExecuted": false, "physicalAudioOutputVerified": false]
    } catch { checks["waveFlowCompleted"] = false; evidence["error"] = error.localizedDescription }
    if let data = try? JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("system-audio-wave.json"))
    }
    return checks
  }
}

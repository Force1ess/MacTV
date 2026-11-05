import Foundation
import MTVCore

extension UISmoke {
  static func systemAudioStereoSmoke(model: AppModel, output: URL) async -> [String: Bool] {
    guard !CommandLine.arguments.contains("--test-vlc-system-audio") else { return ["stereoAudioMustUseNormalStrategy": false] }
    for _ in 0..<400 { if !model.loading && !model.libraryRefreshing { break }; try? await Task.sleep(for: .milliseconds(25)) }
    let original = model.captureLibrarySource(), previous = model.preferredEngine
    defer { model.stopPlayback(); model.preferredEngine = previous; model.restoreLibrarySource(original); model.navigate(.home) }
    var checks: [String: Bool] = [:], measurements: [[String: Any]] = []
    let folder = SystemAudioWaveSource.ownedFixtureURL.deletingLastPathComponent()
    let file = folder.appendingPathComponent("Edited-Stereo-Timeline45.mp4")
    do {
      let source = try await SystemAudioWaveSource.prepare(file: file, start: 0, access: .within(folder), requireEdits: true)
      defer { source.cancel() }
      let wave = source.wave
      checks["stereoAudioPreserves44100AndTwoChannels"] = wave.sampleRate == 44100 && wave.channels == 2 && wave.bytesPerFrame == 8
      for (index, target) in [11.5, 23.5].enumerated() {
        let first = Int64((target * Double(wave.sampleRate)).rounded()), frames = wave.sampleRate / 10
        await source.budget.seek(frame: first)
        let consumer = UUID()
        let pcm = try await source.read(offset: wave.header.count + Int(first) * wave.bytesPerFrame,
          count: frames * wave.bytesPerFrame, consumer: consumer)
        source.releaseConsumer(consumer)
        for channel in 0..<2 {
          let values: [Float] = pcm.withUnsafeBytes { raw in
            (0..<frames).map { raw.loadUnaligned(fromByteOffset: $0 * 8 + channel * 4, as: Float.self) }
          }
          var crossings: [Double] = []
          for i in 1..<values.count where values[i - 1] <= 0 && values[i] > 0 {
            crossings.append(Double(i) - Double(values[i]) / Double(values[i] - values[i - 1]))
          }
          let hz = crossings.count > 1 ? Double(crossings.count - 1) * Double(wave.sampleRate) / (crossings.last! - crossings.first!) : 0
          let expected = channel == 0 ? 400 + 25 * (target + 0.05) : 1000 + 15 * (target + 0.05)
          checks["stereoAudio-\(index)-channel\(channel)-independentContent"] = values.allSatisfy(\.isFinite) && abs(hz - expected) < 2
          measurements.append(["target": target, "channel": channel, "frequencyHz": hz, "expectedHz": expected])
        }
      }
      let root = folder.appendingPathComponent("stereo-source-" + UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      let copy = root.appendingPathComponent("Stereo Timeline.mp4")
      try FileManager.default.copyItem(at: file, to: copy)
      model.useLocalRoot(root)
      for _ in 0..<200 { if !model.libraryRefreshing { break }; try? await Task.sleep(for: .milliseconds(25)) }
      await model.waitForSourceSave(); model.preferredEngine = .vlc
      model.beginPlayback(url: copy, item: MediaItem(id: "owned-system-stereo", title: "自建双声道时间线", url: copy.absoluteString), fromBeginning: true)
      for _ in 0..<160 {
        if (model.vlcEngine?.latest?.elapsed ?? 0) > 1 && (model.vlcEngine?.latest?.displayedPictures ?? 0) > 0 { break }
        if model.playbackInterruption != nil { break }; try? await Task.sleep(for: .milliseconds(50))
      }
      if let engine = model.vlcEngine {
        checks["stereoAudioNormalPlayerSelectsBridge"] = await engine.systemAudioSelectedForTesting()
          && model.playbackSelectionReason.contains("系统音轨") && model.playbackInterruption == nil
        checks["stereoAudioActualVideoDecodes"] = (engine.latest?.displayedPictures ?? 0) > 0 && (engine.latest?.elapsed ?? 0) > 1
        let tracks = await engine.tracks(subtitles: false)
        checks["stereoAudioHasOneReplacementTrack"] = tracks.options.count == 1 && tracks.options.first?.trackID == tracks.selectedID
        let origin = await engine.systemAudioOriginForTesting()
        model.stopPlayback(); await engine.waitUntilStopped()
        if let origin {
          let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.urlCredentialStorage = nil; config.timeoutIntervalForRequest = 2
          let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
          do { _ = try await session.data(from: origin); checks["stereoAudioStopClosesOrigin"] = false }
          catch { checks["stereoAudioStopClosesOrigin"] = true }
        }
      } else { checks["stereoAudioNormalPlayerSelectsBridge"] = false }
      if checks.values.allSatisfy({ $0 }) { try FileManager.default.removeItem(at: root) }
      else { measurements.append(["keptFixtureDirectory": root.path]) }
    } catch { checks["stereoAudioFlowCompleted"] = false; measurements.append(["error": error.localizedDescription]) }
    if let data = try? JSONSerialization.data(withJSONObject: measurements, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("system-audio-stereo.json"))
    }
    return checks
  }
}

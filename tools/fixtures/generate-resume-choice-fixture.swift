import AVFoundation
import Foundation

@main enum GenerateResumeChoiceFixture {
  static func main() async throws {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures")
    let original = AVURLAsset(url: root.appendingPathComponent("PlaybackFixture.mp4"))
    let output = root.appendingPathComponent("ResumeChoice45-v1.mp4")
    if !FileManager.default.fileExists(atPath: output.path) {
      let length = try await original.load(.duration)
      guard length.seconds > 0, length.seconds < 60 else { throw CocoaError(.fileReadCorruptFile) }
      let composition = AVMutableComposition()
      for type in [AVMediaType.video, .audio] {
        guard let source = try await original.loadTracks(withMediaType: type).first,
          let target = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw CocoaError(.fileReadCorruptFile) }
        var cursor = CMTime.zero
        let duration = CMTime(seconds: 45, preferredTimescale: 600)
        while cursor < duration {
          let count = CMTimeMinimum(length, duration - cursor)
          try target.insertTimeRange(CMTimeRange(start: .zero, duration: count), of: source, at: cursor)
          cursor = cursor + count
        }
      }
      // Export a separate edited compatibility sample. The independent cross-engine
      // reference comes from generate-resume-independent-fixture.sh instead.
      guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1280x720)
      else { throw CocoaError(.fileWriteUnknown) }
      try await export.export(to: output, as: .mp4)
    }
    let asset = AVURLAsset(url: output)
    let duration = try await asset.load(.duration).seconds
    guard (44.5...45.5).contains(duration) else { throw CocoaError(.fileReadCorruptFile) }
    var report: [String: Any] = ["duration": duration, "generatedOnly": true, "originalFixtureUnchanged": true]
    for type in [AVMediaType.video, .audio] {
      guard let track = try await asset.loadTracks(withMediaType: type).first else { throw CocoaError(.fileReadCorruptFile) }
      let range = try await track.load(.timeRange)
      guard (44.5...45.5).contains(range.duration.seconds) else { throw CocoaError(.fileReadCorruptFile) }
      report[type.rawValue + "Duration"] = range.duration.seconds
    }
    let generator = AVAssetImageGenerator(asset: asset)
    generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
    for second in [12.0, 30.0] {
      let frame = try await generator.image(at: CMTime(seconds: second, preferredTimescale: 600))
      guard abs(frame.actualTime.seconds - second) < 0.1 else { throw CocoaError(.fileReadCorruptFile) }
      report["frameAt" + String(Int(second))] = frame.actualTime.seconds
    }
    print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), encoding: .utf8)!)
  }
}

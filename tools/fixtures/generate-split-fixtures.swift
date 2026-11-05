import AVFoundation
import Foundation

@main enum GenerateSplitFixtures {
  static func main() async throws {
    let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures")
    let root = base.appendingPathComponent("Split-v1")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let original = AVURLAsset(url: base.appendingPathComponent("ResumeFixture45.mp4"))
    for (name, type, seconds, format) in [("video.mp4", AVMediaType.video, 45.0, AVFileType.mp4),
      ("audio.mp4", .audio, 45.0, .mp4), ("short-audio.mp4", .audio, 20.0, .mp4)] {
      let target = root.appendingPathComponent(name)
      if !FileManager.default.fileExists(atPath: target.path) {
        guard let source = try await original.loadTracks(withMediaType: type).first else { throw CocoaError(.fileReadCorruptFile) }
        let range = try await source.load(.timeRange)
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CocoaError(.fileReadCorruptFile) }
        try track.insertTimeRange(CMTimeRange(start: range.start, duration: CMTimeMinimum(range.duration, CMTime(seconds: seconds, preferredTimescale: 600))), of: source, at: .zero)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else { throw CocoaError(.fileWriteUnknown) }
        try await export.export(to: target, as: format)
      }
      let check = AVURLAsset(url: target)
      let video = try await check.loadTracks(withMediaType: .video).count
      let audio = try await check.loadTracks(withMediaType: .audio).count
      print("Generated \(name): videoTracks=\(video), audioTracks=\(audio), duration=\(try await check.load(.duration).seconds)")
      guard (type == .video ? video == 1 && audio == 0 : video == 0 && audio == 1) else { throw CocoaError(.fileReadCorruptFile) }
    }
  }
}

import AVFoundation
import Foundation

@main enum GenerateResumeFixture {
  static func main() async throws {
    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/MTV/Fixtures")
    let source = AVURLAsset(url: folder.appendingPathComponent("PlaybackFixture.mp4"))
    let output = folder.appendingPathComponent("ResumeFixture45.mp4")
    if !FileManager.default.fileExists(atPath: output.path) {
      let duration = try await source.load(.duration)
      guard duration.seconds > 0 && duration.seconds < 60 else { throw FixtureError.invalidSource }
      let composition = AVMutableComposition()
      for type in [AVMediaType.video, .audio] {
        let tracks = try await source.loadTracks(withMediaType: type)
        guard let original = tracks.first else { continue }
        guard let target = composition.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw FixtureError.invalidSource }
        var cursor = CMTime.zero
        let total = CMTime(seconds: 45, preferredTimescale: 600)
        while cursor < total {
          let length = CMTimeMinimum(duration, total - cursor)
          try target.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: original, at: cursor)
          cursor = cursor + length
        }
      }
      guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough)
      else { throw FixtureError.invalidSource }
      try await exporter.export(to: output, as: .mp4)
    }
    let duration = try await AVURLAsset(url: output).load(.duration).seconds
    guard duration > 44 && duration < 46 else { throw FixtureError.invalidSource }
    print("Generated-only resume fixture duration: \(duration)")
  }
  enum FixtureError: Error { case invalidSource }
}

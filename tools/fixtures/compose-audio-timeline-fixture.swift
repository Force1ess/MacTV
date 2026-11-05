import AVFoundation
import Foundation

@main struct ComposeAudioTimeline {
  static func main() async throws {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/AudioTimeline-v1")
    let output = root.appendingPathComponent("Edited-Audio-Timeline45.mp4")
    guard !FileManager.default.fileExists(atPath: output.path) else { return }
    let composition = AVMutableComposition()
    guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
      let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw CocoaError(.fileWriteUnknown) }
    var cursor = CMTime.zero
    for index in 0..<4 {
      let asset = AVURLAsset(url: root.appendingPathComponent("Segment-\(index).mp4"))
      let length = CMTime(seconds: index == 3 ? 9 : 12, preferredTimescale: 600)
      guard let v = try await asset.loadTracks(withMediaType: .video).first, let a = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
      try video.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: v, at: cursor)
      try audio.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: a, at: cursor)
      cursor = cursor + length
    }
    guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPreset1280x720) else { throw CocoaError(.fileWriteUnknown) }
    try await export.export(to: output, as: .mp4)
    print(output.path)
  }
}

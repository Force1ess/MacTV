import AVFoundation
import Foundation

@main struct InspectMP4Timeline {
  static func main() async throws {
    guard CommandLine.arguments.count > 1 else { throw CocoaError(.fileReadInvalidFileName) }
    var samples: [[String: Any]] = []
    for path in CommandLine.arguments.dropFirst() {
      let asset = AVURLAsset(url: URL(fileURLWithPath: path))
      var tracks: [[String: Any]] = []
      for track in try await asset.load(.tracks) {
        let segments = try await track.load(.segments)
        let values: [[String: Any]] = segments.map { segment in
          let mapping = segment.timeMapping
          return ["empty": segment.isEmpty, "sourceStart": mapping.source.start.seconds,
            "sourceDuration": mapping.source.duration.seconds, "targetStart": mapping.target.start.seconds,
            "targetDuration": mapping.target.duration.seconds]
        }
        tracks.append(["mediaType": track.mediaType.rawValue, "segments": values])
      }
      samples.append(["sample": URL(fileURLWithPath: path).lastPathComponent, "tracks": tracks])
    }
    print(String(decoding: try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
  }
}

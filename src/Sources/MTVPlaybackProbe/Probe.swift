import AVFoundation
import CoreVideo
import Foundation

@main struct Probe {
  @MainActor static func main() async {
    guard CommandLine.arguments.count >= 2 else {
      print("Usage: MTVPlaybackProbe /path/to/media [--raw]")
      exit(2)
    }
    let original = URL(fileURLWithPath: CommandLine.arguments[1])
    let url =
      CommandLine.arguments.contains("--raw") ? original : original.resolvingSymlinksInPath()
    let item = AVPlayerItem(url: url)
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
    ])
    item.add(output)
    let player = AVPlayer(playerItem: item)
    player.volume = 0
    player.play()
    for _ in 0..<150 {
      if player.currentTime().seconds > 2 || item.status == .failed { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    let time = player.currentTime().seconds
    let frame = output.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil)
    var videoFormats: [String] = []
    var audioOptions = 0
    var subtitleOptions = 0
    if item.status == .readyToPlay {
      if let tracks = try? await item.asset.loadTracks(withMediaType: .video) {
        for track in tracks {
          if let formats = try? await track.load(.formatDescriptions) {
            videoFormats += formats.map { fourCC(CMFormatDescriptionGetMediaSubType($0)) }
          }
        }
      }
      audioOptions =
        (try? await item.asset.loadMediaSelectionGroup(for: .audible))?.options.count ?? 0
      subtitleOptions =
        (try? await item.asset.loadMediaSelectionGroup(for: .legible))?.options.count ?? 0
    }
    let report: [String: Any] = [
      "itemStatus": item.status.rawValue, "timeControlStatus": player.timeControlStatus.rawValue,
      "elapsed": time.isFinite ? time : 0,
      "error": item.error?.localizedDescription ?? "",
      "waitingReason": player.reasonForWaitingToPlay?.rawValue ?? "",
      "timelineAdvanced": time.isFinite && time > 2,
      "decodedFrame": frame != nil, "videoFormats": videoFormats,
      "audioOptions": audioOptions, "subtitleOptions": subtitleOptions,
      "hdrOutputVerified": false, "audioOutputVerified": false,
    ]
    player.pause()
    let data = try! JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
    exit(time > 2 ? 0 : 1)
  }
  static func fourCC(_ value: FourCharCode) -> String {
    String(
      bytes: [
        UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255),
        UInt8(value & 255),
      ], encoding: .ascii) ?? String(value)
  }
}

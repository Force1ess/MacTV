import Darwin
import Foundation
import VLCBridge

@main struct Probe {
  static func main() async {
    guard CommandLine.arguments.count == 3 else {
      print("Usage: MTVVLCProbe /engine/root /fixture")
      exit(2)
    }
    var error = [CChar](repeating: 0, count: 2048)
    let termBefore = mtv_vlc_signal_mode(SIGTERM)
    guard let handle = mtv_vlc_create(CommandLine.arguments[1], 1, &error, error.count) else {
      emit(["error": String(cString: error), "engine": "libVLC"])
      exit(1)
    }
    defer { mtv_vlc_destroy(handle) }
    let url = URL(fileURLWithPath: CommandLine.arguments[2]).absoluteString
    let started = mtv_vlc_play(handle, url, nil, 1, 0, 0)
    var stats = mtv_vlc_stats(handle)
    for _ in 0..<150 {
      stats = mtv_vlc_stats(handle)
      if stats.time_ms > 2000 && stats.decoded_video > 0 || stats.state == 7 { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    let result: [String: Any] = [
      "engine": "libVLC", "version": String(cString: mtv_vlc_version(handle)),
      "startCode": started, "state": stats.state, "elapsed": Double(stats.time_ms) / 1000,
      "duration": Double(stats.length_ms) / 1000, "decodedVideoFrames": stats.decoded_video,
      "decodedAudioBlocks": stats.decoded_audio, "displayedPictures": stats.displayed_pictures,
      "width": stats.width, "height": stats.height, "audioOptions": stats.audio_count,
      "subtitleOptions": stats.subtitle_count, "selectedSubtitle": stats.subtitle_id,
      "timelineAdvanced": stats.time_ms > 2000, "decodedFrame": stats.decoded_video > 0,
      "hdrOutputVerified": false, "physicalAudioVerified": false,
      "sigtermBefore": termBefore, "sigtermAfter": mtv_vlc_signal_mode(SIGTERM),
    ]
    emit(result)
  }
  static func emit(_ value: [String: Any]) {
    let data = try! JSONSerialization.data(
      withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    print(String(data: data, encoding: .utf8)!)
  }
}

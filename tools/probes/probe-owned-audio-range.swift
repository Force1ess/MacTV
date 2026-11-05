// Diagnostic only. Read at most two seconds from the project's generated movie.
// This is not an application audio bridge and never reads a user's media.
import AVFoundation
import Foundation

struct OwnedAudioRangeSource {
  let asset: AVURLAsset
  let track: AVAssetTrack
  init() async throws {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let fixture = home.appendingPathComponent("Library/Application Support/MTV/Fixtures/AudioTimeline-v1/Edited-Audio-Timeline45.mp4")
    asset = AVURLAsset(url: fixture)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
    self.track = track
  }
  // The caller must serialize reads. No mutable decoder or whole-track cache.
  func read(first: Int64, frames: Int64, floating: Bool = false) throws -> (pcm: Data, report: [String: Any]) {
    guard first >= 0, first <= 45 * 48000, frames > 0, frames <= 96000,
      frames <= 45 * 48000 - first else { throw NSError(domain: "OwnedAudioRangeArguments", code: 2) }
    let end = first + frames
    let stride = floating ? 4 : 2
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(start: CMTime(value: first, timescale: 48000), duration: CMTime(value: frames, timescale: 48000))
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: floating ? 32 : 16, AVLinearPCMIsFloatKey: floating, AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
    var pcm = Data(), next = first, buffers = 0, maximumBufferBytes = 0
    while let sample = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(sample) else { throw CocoaError(.fileReadCorruptFile) }
      let time = CMSampleBufferGetPresentationTimeStamp(sample)
      guard time.isNumeric else { throw CocoaError(.fileReadCorruptFile) }
      let position = CMTimeConvertScale(time, timescale: 48000, method: .roundHalfAwayFromZero).value
      let size = CMBlockBufferGetDataLength(block)
      guard size > 0, size % stride == 0, size <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
      maximumBufferBytes = max(maximumBufferBytes, size); buffers += 1
      let lower = max(first, position), upper = min(end, position + Int64(size / stride))
      guard lower <= next else { throw NSError(domain: "OwnedAudioRangeGap", code: 1, userInfo: ["next": next, "position": position]) }
      if upper > next {
        let count = Int(upper - next) * stride, old = pcm.count
        guard old + count <= Int(frames) * stride else { throw CocoaError(.fileReadTooLarge) }
        pcm.count += count
        let status = pcm.withUnsafeMutableBytes { bytes in
          CMBlockBufferCopyDataBytes(block, atOffset: Int(next - position) * stride, dataLength: count,
            destination: bytes.baseAddress!.advanced(by: old))
        }
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        next = upper
      }
    }
    guard reader.status == .completed, next == end else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
    let report: [String: Any] = ["startFrame": first, "requestedFrames": frames, "writtenFrames": pcm.count / stride,
      "format": floating ? "F32LE" : "S16LE",
      "decodedBuffers": buffers, "maximumDecodedBufferBytes": maximumBufferBytes, "readEntireTrack": false,
      "physicalAudioOutputVerified": false]
    return (pcm, report)
  }
}

#if !MTV_OWNED_AUDIO_RANGE_LIBRARY
@main struct OwnedAudioRangeProbe {
  static func main() async throws {
    let args = CommandLine.arguments
    let build = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Developer/MTV/.build", isDirectory: true)
    guard (args.count == 4 || (args.count == 5 && args[4] == "float")), let start = Double(args[1]), let duration = Double(args[2]),
      start.isFinite, duration.isFinite, start >= 0, duration > 0, duration <= 2,
      start + duration <= 45 else { throw NSError(domain: "OwnedAudioRangeArguments", code: 1) }
    let destination = URL(fileURLWithPath: args[3]).standardizedFileURL
    guard destination.deletingLastPathComponent() == build.standardizedFileURL,
      destination.lastPathComponent.hasPrefix("owned-audio-range-"),
      !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteNoPermission) }
    let source = try await OwnedAudioRangeSource()
    let value = try source.read(first: Int64((start * 48000).rounded()), frames: Int64((duration * 48000).rounded()), floating: args.count == 5)
    try value.pcm.write(to: destination, options: .withoutOverwriting)
    print(String(decoding: try JSONSerialization.data(withJSONObject: value.report, options: [.sortedKeys]), as: UTF8.self))
  }
}
#endif

// Streaming reference decoder for the fixed generated 45-second chirp only.
// Development evidence, not a runtime whole-track cache.
import AVFoundation
import Foundation

@main struct OwnedFloatReference {
  static func main() async throws {
    let args = CommandLine.arguments, home = FileManager.default.homeDirectoryForCurrentUser
    guard args.count == 2 else { throw NSError(domain: "OwnedFloatReferenceArguments", code: 1) }
    let destination = URL(fileURLWithPath: args[1]).standardizedFileURL
    let build = home.appendingPathComponent("Developer/MTV/.build", isDirectory: true).standardizedFileURL
    guard destination.deletingLastPathComponent() == build,
      destination.lastPathComponent.hasPrefix("owned-float-reference-"), destination.pathExtension == "f32" else { throw CocoaError(.fileWriteNoPermission) }
    let fixture = home.appendingPathComponent("Library/Application Support/MTV/Fixtures/AudioTimeline-v1/Edited-Audio-Timeline45.mp4")
    let asset = AVURLAsset(url: fixture)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
    reader.add(output)
    try Data().write(to: destination, options: .withoutOverwriting)
    let file = try FileHandle(forWritingTo: destination); defer { try? file.close() }
    guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
    var next: Int64 = 0, bytesWritten = 0
    while let sample = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(sample) else { throw CocoaError(.fileReadCorruptFile) }
      let time = CMSampleBufferGetPresentationTimeStamp(sample)
      guard time.isNumeric else { throw CocoaError(.fileReadCorruptFile) }
      let position = CMTimeConvertScale(time, timescale: 48000, method: .roundHalfAwayFromZero).value
      let count = CMBlockBufferGetDataLength(block)
      guard position == next, count > 0, count % 4 == 0, count <= 1_048_576,
        bytesWritten + count <= 45 * 48000 * 4 else { throw CocoaError(.fileReadCorruptFile) }
      var data = Data(count: count)
      let status = data.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count, destination: $0.baseAddress!) }
      guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
      try file.write(contentsOf: data); bytesWritten += count; next += Int64(count / 4)
    }
    guard reader.status == .completed, next == 45 * 48000 else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
    print("Wrote fixed-fixture Float32 reference: \(next) frames, \(bytesWritten) bytes; physical audio not measured.")
  }
}

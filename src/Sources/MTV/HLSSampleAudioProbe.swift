import AVFoundation
import AudioToolbox
import Foundation

enum HLSSampleAudioProbe {
  /// Reading is confined to one worker; AVAssetReader's cancellation API is used from the canceller.
  private final class ReaderBox: @unchecked Sendable {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    init(_ reader: AVAssetReader, _ output: AVAssetReaderTrackOutput) { self.reader = reader; self.output = output }
  }
  /// Independent AAC sample decoding, not an HLS render tap or a physical-output measurement.
  static func decode(_ data: Data) async throws -> [String: Int] {
    guard CommandLine.arguments.contains("--ui-smoke"), data.count <= 2_097_152 else { throw CocoaError(.featureUnsupported) }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MTV-AudioProbe-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("sample.mp4")
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    let asset = AVURLAsset(url: file, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
      AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true])
    guard reader.canAdd(output) else { throw CocoaError(.fileReadCorruptFile) }
    reader.add(output)
    let box = ReaderBox(reader, output)
    return try await withTaskCancellationHandler(operation: {
      try await Task.detached(priority: .utility) {
        let reader = box.reader, output = box.output
        defer { reader.cancelReading() }
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(),
          let format = CMSampleBufferGetFormatDescription(sample), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format),
          asbd.pointee.mFormatID == kAudioFormatLinearPCM, asbd.pointee.mBitsPerChannel == 32,
          asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0,
          let block = CMSampleBufferGetDataBuffer(sample) else { throw CocoaError(.fileReadCorruptFile) }
        let length = CMBlockBufferGetDataLength(block)
        guard length > 0, length <= 1_048_576, length.isMultiple(of: 4) else { throw CocoaError(.fileReadCorruptFile) }
        var values = [Float](repeating: 0, count: length / 4)
        let result = values.withUnsafeMutableBytes { buffer in CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: buffer.baseAddress!) }
        guard result == noErr else { throw CocoaError(.fileReadCorruptFile) }
        reader.cancelReading()
        return ["frames": CMSampleBufferGetNumSamples(sample), "nonzeroSamples": values.filter { $0.isFinite && abs($0) > 0.001 }.count]
      }.value
    }, onCancel: { box.reader.cancelReading() })
  }
}

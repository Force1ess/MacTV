import AVFoundation
import Foundation

@main struct InspectAudioChirp {
  static func main() async throws {
    guard (2...3).contains(CommandLine.arguments.count) else { throw CocoaError(.fileReadInvalidFileName) }
    let asset = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
    reader.add(output); guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
    var data = Data()
    while let sample = output.copyNextSampleBuffer() {
      guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
      let size = CMBlockBufferGetDataLength(block), old = data.count
      guard old + size <= 10_000_000 else { throw CocoaError(.fileReadTooLarge) }
      data.count += size
      let status = data.withUnsafeMutableBytes { buffer in CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: buffer.baseAddress!.advanced(by: old)) }
      guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
    guard reader.status == .completed else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
    if CommandLine.arguments.count == 3 {
      let owned = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/AudioTimeline-v1/Edited-Audio-Timeline45.mp4")
      guard URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath() == owned.resolvingSymlinksInPath() else { throw CocoaError(.fileReadNoPermission) }
      try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .withoutOverwriting)
    }
    var rows: [[String: Any]] = []
    data.withUnsafeBytes { raw in
      let pcm = raw.bindMemory(to: Int16.self)
      for start in stride(from: 0, to: pcm.count - 4800, by: 4800) {
        var first = 0.0, last = 0.0, count = 0, sum = 0.0
        for index in start..<(start + 4800) {
          let value = Int(pcm[index]); sum += pow(Double(value) / 32768, 2)
          if index > 0, pcm[index - 1] <= 0, value > 0 {
            let location = Double(index - start) - Double(value) / Double(value - Int(pcm[index - 1]))
            if count == 0 { first = location }; last = location; count += 1
          }
        }
        let frequency = count > 1 && last > first ? Double(count - 1) * 48000 / (last - first) : 0
        let time = (Double(start) + (first + last) * 0.5) / 48000
        if [12.0,24.0,36.0].contains(where: { abs(time - $0) < 0.6 }) {
          rows.append(["time": time, "frequencyHz": frequency, "expectedFrequency": 400 + 25 * time, "rms": sqrt(sum / 4800)])
        }
      }
    }
    print(String(decoding: try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
  }
}

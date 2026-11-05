import AVFoundation
import CoreVideo
import Foundation
import VideoToolbox

// Generated neutral ramps exercise 10-bit transfer signaling, not display calibration.
@main enum GenerateHDRFixtures {
  enum Failure: Error { case buffer, writer(String), timeout }
  static func main() async throws {
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/MTV/Fixtures/HDR-v1")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for (name, transfer, insertion) in [("HLG", AVVideoTransferFunction_ITU_R_2100_HLG, kVTHDRMetadataInsertionMode_None),
      ("PQ", AVVideoTransferFunction_SMPTE_ST_2084_PQ, kVTHDRMetadataInsertionMode_None),
      ("HLG-Auto", AVVideoTransferFunction_ITU_R_2100_HLG, kVTHDRMetadataInsertionMode_Auto)] {
      let url = root.appendingPathComponent(name + ".mp4")
      if !FileManager.default.fileExists(atPath: url.path) {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
          AVVideoCodecKey: AVVideoCodecType.hevc,
          AVVideoWidthKey: 640, AVVideoHeightKey: 360,
          AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey: transfer, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020],
          AVVideoCompressionPropertiesKey: [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel,
            kVTCompressionPropertyKey_HDRMetadataInsertionMode as String: insertion]
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
          kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360,
          kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        guard writer.canAdd(input) else { throw Failure.writer("cannot add video") }
        writer.add(input)
        guard writer.startWriting() else { throw Failure.writer(writer.error?.localizedDescription ?? "start") }
        writer.startSession(atSourceTime: .zero)
        let deadline = Date().addingTimeInterval(30)
        do {
          for frame in 0..<150 {
            while !input.isReadyForMoreMediaData {
              guard Date() < deadline, writer.status == .writing else {
                throw Failure.writer(writer.error?.localizedDescription ?? "encoder did not become ready")
              }
              try await Task.sleep(for: .milliseconds(5))
            }
            guard let pool = adaptor.pixelBufferPool else { throw Failure.buffer }
            var optional: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optional) == kCVReturnSuccess,
              let buffer = optional, CVPixelBufferGetPlaneCount(buffer) == 2 else { throw Failure.buffer }
            CVPixelBufferLockBaseAddress(buffer, [])
            for plane in 0..<2 {
              guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { throw Failure.buffer }
              let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2
              let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
              let columns = CVPixelBufferGetWidthOfPlane(buffer, plane) * (plane == 0 ? 1 : 2)
              let pixels = base.assumingMemoryBound(to: UInt16.self)
              for y in 0..<rows {
                for x in 0..<columns {
                  let code = plane == 0 ? 64 + (x * 876 / 639) : 512
                  pixels[y * stride + x] = UInt16(code << 6)
                }
              }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer as CFString, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
              throw Failure.writer(writer.error?.localizedDescription ?? "append")
            }
          }
          input.markAsFinished()
          await writer.finishWriting()
          guard writer.status == .completed else { throw Failure.writer(writer.error?.localizedDescription ?? "finish") }
        } catch {
          writer.cancelWriting()
          try? FileManager.default.removeItem(at: url)
          throw error
        }
      }
      let asset = AVURLAsset(url: url)
      let duration = try await asset.load(.duration).seconds
      guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.buffer }
      let (formats, characteristics) = try await track.load(.formatDescriptions, .mediaCharacteristics)
      guard let format = formats.first else { throw Failure.buffer }
      let properties = (CMFormatDescriptionGetExtensions(format) as? [String: Any]) ?? [:]
      let actual = properties[kCMFormatDescriptionExtension_TransferFunction as String] as? String
      let atoms = properties[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] ?? [:]
      guard actual == transfer, duration > 4.9 else { throw Failure.writer("signal mismatch") }
      print("Generated \(name): \(duration)s; transfer=\(actual!); containsHDR=\(characteristics.contains(.containsHDRVideo)); formatAtoms=\(atoms.keys.sorted())")
    }
  }
}

import AppKit
import Foundation
import MTVCore
import Vision

/// Read only the fixed, burned markers on MTV-generated compatibility samples.
enum OwnedFixtureTimecode {
  static func read(_ image: CGImage, rate: Double, period: Double) throws -> (seconds: Double, method: String) {
    guard let crop = image.cropping(to: CGRect(x: 0, y: 0, width: min(120, image.width), height: min(45, image.height))) else { throw CocoaError(.fileReadCorruptFile) }
    let regex = try NSRegularExpression(pattern: #"(\d{2}):(\d{2}):(\d{2})[.](\d{3})"#)
    for scale in [1, 4] {
      var input = crop
      if scale > 1, let context = CGContext(data: nil, width: crop.width * scale, height: crop.height * scale, bitsPerComponent: 8, bytesPerRow: crop.width * scale * 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        context.interpolationQuality = .none; context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width * scale, height: crop.height * scale))
        input = context.makeImage() ?? crop
      }
      let request = VNRecognizeTextRequest(); request.recognitionLanguages = ["en-US"]; request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
      try VNImageRequestHandler(cgImage: input).perform([request])
      var timestamp: Double?, counter: Double?
      for observation in request.results ?? [] {
        guard let text = observation.topCandidates(1).first?.string.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: "O", with: "0") else { continue }
        if let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) {
          let value = text as NSString
          let numbers = (1...4).map { Double(value.substring(with: match.range(at: $0))) ?? -1 }
          if numbers[1] < 60, numbers[2] < 60 { timestamp = numbers[0] * 3600 + numbers[1] * 60 + numbers[2] + numbers[3] / 1000 }
        }
        if observation.boundingBox.midY < 0.6, text.range(of: #"^\d{1,4}$"#, options: .regularExpression) != nil,
          let number = Double(text), number >= 0, number < period * rate { counter = number / rate }
      }
      if let timestamp, let counter, abs(timestamp - counter) > 1.1 / rate { continue }
      if let timestamp { return (timestamp, "timestamp") }
      if let counter { return (counter, "burned-frame-counter") }
    }
    throw MTVError.message("自建片源截图未读到画面时间码或下方帧计数")
  }
}

import AppKit
import Foundation
import Vision

@main struct InspectTimecodeImage {
  static func main() throws {
    for path in CommandLine.arguments.dropFirst() {
      guard let image = NSImage(contentsOfFile: path)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
        let crop = image.cropping(to: CGRect(x: 0, y: 0, width: min(120, image.width), height: min(45, image.height))) else { continue }
      let request = VNRecognizeTextRequest(); request.recognitionLanguages = ["en-US"]
      request.recognitionLevel = .accurate; request.usesLanguageCorrection = false
      try VNImageRequestHandler(cgImage: crop).perform([request])
      let texts = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
      print(String(decoding: try JSONSerialization.data(withJSONObject: ["sample": URL(fileURLWithPath: path).lastPathComponent, "texts": texts]), as: UTF8.self))
    }
  }
}

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

@main enum GenerateArtworkFixture {
  static func main() throws {
    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures")
    let output = folder.appendingPathComponent("GeneratedPoster.png")
    guard !FileManager.default.fileExists(atPath: output.path) else { print("Generated poster already present"); return }
    let context = CGContext(data: nil, width: 360, height: 540, bitsPerComponent: 8, bytesPerRow: 1440,
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(red: 0.04, green: 0.12, blue: 0.26, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 360, height: 540))
    for row in 0..<12 {
      context.setFillColor(CGColor(red: 0.05, green: 0.3 + Double(row) * 0.035, blue: 0.75, alpha: 1))
      context.fill(CGRect(x: 40 + row * 4, y: 55 + row * 35, width: 240 - row * 7, height: 18))
    }
    let data = NSMutableData()
    let target = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(target, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(target) else { throw CocoaError(.fileWriteUnknown) }
    try (data as Data).write(to: output, options: .atomic)
    print("Generated-only portrait fixture: 360x540")
  }
}

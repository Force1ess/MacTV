import AVFoundation
import AppKit
import MTVCore

@MainActor enum VideoThumbnail {
  struct Request: Hashable {
    let url: URL
    let access: ArtworkFileAccess
    let revision: UInt64
  }

  private static let gate = AsyncWorkGate(limit: 2)
  private static let cache: NSCache<NSURL, NSImage> = {
    let cache = NSCache<NSURL, NSImage>()
    cache.countLimit = 160
    return cache
  }()
  private static var revisions: [URL: Request] = [:]

  static func image(for request: Request) async -> NSImage? {
    guard let path = try? ScopedFileReader.canonicalPath(request.url) else { return nil }
    let boundary: URL?
    switch request.access {
    case .denied: return nil
    case .unrestricted: boundary = nil
    case .within(let root): boundary = root
    case .verifiedSMB(let share):
      guard (try? share.validateCurrentMount()) != nil,
        let root = try? ScopedFileReader.canonicalPath(share.mount) else { return nil }
      boundary = URL(fileURLWithPath: root)
    }
    if let boundary, !path.hasPrefix(boundary.path == "/" ? "/" : boundary.path + "/") { return nil }
    let file = URL(fileURLWithPath: path)
    if revisions[file] == request, let image = cache.object(forKey: file as NSURL) { return image }
    guard let frame = try? await gate.run({
      let asset = AVURLAsset(url: file)
      let duration = try await asset.load(.duration).seconds
      guard duration.isFinite, duration > 0 else { return nil as CGImage? }
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 480, height: 360)
      for fraction in [0.25, 0.5, 0.75] {
        try Task.checkCancellation()
        let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
        if let result = try? await generator.image(at: time), !isDark(result.image) { return result.image }
      }
      return nil
    }), !Task.isCancelled else { return nil }
    if case .verifiedSMB(let share) = request.access, (try? share.validateCurrentMount()) == nil { return nil }
    let image = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
    if revisions.count >= 512 { revisions.removeAll(); cache.removeAllObjects() }
    revisions[file] = request
    cache.setObject(image, forKey: file as NSURL)
    return image
  }

  nonisolated private static func isDark(_ frame: CGImage) -> Bool {
    var pixels = [UInt8](repeating: 0, count: 8 * 8 * 4)
    return pixels.withUnsafeMutableBytes { bytes in
      guard let context = CGContext(data: bytes.baseAddress, width: 8, height: 8, bitsPerComponent: 8,
        bytesPerRow: 32, space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
      context.draw(frame, in: CGRect(x: 0, y: 0, width: 8, height: 8))
      let rgba = bytes.bindMemory(to: UInt8.self)
      return stride(from: 0, to: rgba.count, by: 4).allSatisfy {
        max(rgba[$0], max(rgba[$0 + 1], rgba[$0 + 2])) < 24
      }
    }
  }
}

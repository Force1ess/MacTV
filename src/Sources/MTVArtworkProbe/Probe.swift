import Foundation
import ImageIO
import MTVCore

@main enum Probe {
  static func main() async throws {
    guard CommandLine.arguments.count == 4, let url = URL(string: CommandLine.arguments[3]),
      NetworkPolicy.permits(url, domains: [url.host ?? ""])
    else {
      throw MTVError.message("Pass fetch/offline, cache directory and public HTTPS image URL")
    }
    let offline = CommandLine.arguments[1] == "offline"
    guard offline || CommandLine.arguments[1] == "fetch" else {
      throw MTVError.message("Unsupported cache probe mode")
    }
    let store = ArtworkDiskStore(root: URL(fileURLWithPath: CommandLine.arguments[2]))
    if !offline {
      let configuration = URLSessionConfiguration.ephemeral
      configuration.httpCookieStorage = nil
      configuration.urlCredentialStorage = nil
      let session = URLSession(configuration: configuration)
      defer { session.invalidateAndCancel() }
      let (data, response) = try await session.data(from: url)
      guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 15_000_000,
        CGImageSourceCreateWithData(data as CFData, nil) != nil
      else { throw MTVError.message("Image download/format failed") }
      try await store.write(data, for: url)
    }
    guard let data = try await store.read(url),
      let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(
        source, 0,
        [
          kCGImageSourceCreateThumbnailFromImageAlways: true,
          kCGImageSourceThumbnailMaxPixelSize: 1800,
        ] as CFDictionary)
    else { throw MTVError.message("Disk artwork decode failed") }
    print(
      String(
        decoding: try JSONSerialization.data(
          withJSONObject: [
            "offline": offline, "networkRequested": !offline,
            "decoded": image.width > 0 && image.height > 0, "width": image.width,
            "height": image.height,
          ], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
  }
}

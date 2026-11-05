import AVFoundation
import Foundation
import MTVCore

actor MusicArtwork {
  static let shared = MusicArtwork()
  private var entries: [String:(String,String)] = [:]
  private var tokens: [String:String] = [:]
  private let cache = NSCache<NSString,NSData>()
  private init() { cache.totalCostLimit = 16_000_000 }
  func reference(owner: String, track: String) -> String {
    let key = owner + ":" + track
    let token = tokens[key] ?? UUID().uuidString.lowercased()
    tokens[key] = token; entries[token] = (owner,track)
    return "mactv-music-artwork://" + token
  }
  func data(_ url: URL) async throws -> Data {
    guard url.scheme == "mactv-music-artwork", let token = url.host, let (owner,track) = entries[token] else { throw MTVError.message("Unknown music artwork") }
    return try await data(owner:owner,track:track)
  }
  func data(owner: String, track: String) async throws -> Data {
    let file = try NativeLibrary.shared.asset(pluginID:owner,services:["music"],reference:track,kind:.audio)
    let key = (owner + ":" + track) as NSString
    if let data = cache.object(forKey:key) { return data as Data }
    let asset = AVURLAsset(url:file)
    let metadata = try await asset.load(.commonMetadata)
    for item in AVMetadataItem.metadataItems(from:metadata,filteredByIdentifier:.commonIdentifierArtwork) {
      try Task.checkCancellation()
      if let data = try await item.load(.dataValue), !data.isEmpty, data.count <= 8_000_000 {
        cache.setObject(data as NSData,forKey:key,cost:data.count); return data
      }
    }
    throw MTVError.message("This song has no embedded artwork.")
  }
}

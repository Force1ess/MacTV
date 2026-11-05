import Foundation
import MTVCore

/// A nonce-routed local origin for an authenticated original file. Remote URLs
/// and account headers stay in RemoteRangeClient, never in mpv or its logs.
final class OriginalRemoteMedia: @unchecked Sendable {
  struct Transfer:Sendable {
    let chunkBytes:Int, depth:Int, initialDepth:Int
    let useSystemProxy:Bool
  }
  let url: URL
  let transfer:Transfer
  private let client: RemoteRangeClient
  private let server: LoopbackMediaServer
  private init(url: URL, client: RemoteRangeClient, server: LoopbackMediaServer, transfer:Transfer) {
    self.url = url; self.client = client; self.server = server; self.transfer=transfer
  }
  static func prepare(_ request: RemotePlaybackRequest) async throws -> OriginalRemoteMedia {
    let args = CommandLine.arguments
    func experiment(_ name: String, allowed: [Int], fallback: Int) -> Int {
      guard args.contains("--ui-smoke"), args.contains("--playback-benchmark-only"),
        let index = args.firstIndex(of: name), index + 1 < args.count,
        let value = Int(args[index + 1]), allowed.contains(value) else { return fallback }
      return value
    }
    let chunkSize = experiment("--benchmark-range-bytes", allowed: [65536,131072,262144,1048576,4194304,10485760], fallback: 10485760)
    let depth = experiment("--benchmark-range-depth", allowed: [1,2,3,4], fallback: 3)
    let headFirst = args.contains("--ui-smoke") && args.contains("--playback-benchmark-only") && args.contains("--benchmark-head-first")
    let direct = args.contains("--ui-smoke") && args.contains("--playback-benchmark-only") &&
      args.contains("--benchmark-original-file") && args.contains("--benchmark-direct-origin")
    let client = RemoteRangeClient(request,useSystemProxy:!direct)
    let transfer=Transfer(chunkBytes:chunkSize,depth:depth,initialDepth:headFirst ? 1:depth,useSystemProxy:!direct)
    do {
      let prefix = try await client.fetch(offset: 0, count: 262144)
      guard ContainerInspection.matroskaHeader(prefix.data), prefix.totalLength <= Int64(Int.max) else {
        throw MTVError.message("The original stream is not a supported Matroska file.")
      }
      await client.seedPrefix(prefix)
      let route = "/original/" + UUID().uuidString.lowercased() + "/movie.mkv"
      let length = Int(prefix.totalLength)
      let server = LoopbackMediaServer(rangeChunkSize:transfer.chunkBytes,rangeDepth:transfer.depth,initialRangeDepth:transfer.initialDepth) { path in
        guard path == route else { throw MTVError.message("Unknown original-media route") }
        return .remote(client, offset: 0, length: length, mime: "video/x-matroska")
      }
      do {
        let port = try await server.start()
        let url = URL(string: "http://127.0.0.1:\(port)" + route)!
        return OriginalRemoteMedia(url: url, client: client, server: server, transfer:transfer)
      } catch { server.cancel(); throw error }
    } catch { client.cancel(); throw error }
  }
  func cancel() { server.cancel(); client.cancel() }
  func statistics() async -> (requests: Int, received: Int, prefixHits: Int) { await client.statistics() }
  func benchmarkTrace() async -> [[String:Double]] { await client.benchmarkTrace() }
  deinit { cancel() }
}

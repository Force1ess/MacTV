import AVFoundation
import Foundation
import MTVCore

/// Converts only an authorized clear AVC/AAC indexed file pair into a local HLS origin.
final class IndexedHLSMedia: @unchecked Sendable {
  let asset: AVURLAsset
  let port: UInt16
  private let server: LoopbackMediaServer
  private let video: RemoteRangeClient
  private let audio: RemoteRangeClient
  let videoIndex: FragmentedMediaIndex
  let audioIndex: FragmentedMediaIndex
  private init(asset: AVURLAsset, port: UInt16, server: LoopbackMediaServer, video: RemoteRangeClient,
    audio: RemoteRangeClient, videoIndex: FragmentedMediaIndex, audioIndex: FragmentedMediaIndex) {
    self.asset = asset; self.port = port; self.server = server; self.video = video; self.audio = audio
    self.videoIndex = videoIndex; self.audioIndex = audioIndex
  }
  static func prepare(video request: RemotePlaybackRequest, audio audioRequest: RemotePlaybackRequest) async throws -> IndexedHLSMedia {
    let video = RemoteRangeClient(request), audio = RemoteRangeClient(audioRequest)
    var server: LoopbackMediaServer?
    do {
      return try await withTaskCancellationHandler(operation: {
        async let picture = video.fetch(offset: 0, count: 262_144)
        async let sound = audio.fetch(offset: 0, count: 262_144)
        let (videoHeader, audioHeader) = try await (picture, sound)
        let vi = try FragmentedMediaIndex.parse(videoHeader.data, totalLength: videoHeader.totalLength)
        let ai = try FragmentedMediaIndex.parse(audioHeader.data, totalLength: audioHeader.totalLength)
        guard ["avc1", "avc3"].contains(vi.codec), ai.codec == "mp4a",
          abs(vi.duration - ai.duration) <= 0.5 else { throw MTVError.message("索引音视频格式或时间范围不匹配") }
        let benchmark = CommandLine.arguments.contains("--ui-smoke") && CommandLine.arguments.contains("--playback-benchmark-only")
        if !benchmark || CommandLine.arguments.contains("--benchmark-prefix-cache") {
          await video.seedPrefix(videoHeader); await audio.seedPrefix(audioHeader)
        }
        let nonce = UUID().uuidString.lowercased()
        let root = "/" + nonce
        let master = "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"sound\",NAME=\"Audio\",DEFAULT=YES,AUTOSELECT=YES,URI=\"\(root)/a/index.m3u8\"\n#EXT-X-STREAM-INF:BANDWIDTH=\(vi.bandwidth + ai.bandwidth),AUDIO=\"sound\"\n\(root)/v/index.m3u8\n"
        let vp = try vi.playlist(prefix: root + "/v"), ap = try ai.playlist(prefix: root + "/a")
        let origin = LoopbackMediaServer { path in
          if path == root + "/master.m3u8" { return .data(Data(master.utf8), mime: "application/vnd.apple.mpegurl") }
          for (role, index, client, playlist) in [("v", vi, video, vp), ("a", ai, audio, ap)] {
            let prefix = root + "/" + role + "/"
            if path == prefix + "index.m3u8" { return .data(Data(playlist.utf8), mime: "application/vnd.apple.mpegurl") }
            if path == prefix + "init.mp4" { return .data(index.initialization, mime: "video/mp4") }
            if path.hasPrefix(prefix), path.hasSuffix(".m4s") {
              let name = path.dropFirst(prefix.count).dropLast(4)
              guard !name.isEmpty, name.allSatisfy(\.isNumber), let value = Int(name), index.segments.indices.contains(value) else { throw MTVError.message("无效的内部片段编号") }
              let segment = index.segments[value]
              return .remote(client, offset: segment.offset, length: segment.length, mime: "video/mp4")
            }
          }
          throw MTVError.message("内部媒体路径未授权")
        }
        server = origin
        let port = try await origin.start()
        try Task.checkCancellation()
        let url = URL(string: "http://127.0.0.1:\(port)\(root)/master.m3u8")!
        let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey:
          AVAssetReferenceRestrictions([.forbidCrossSiteReference, .forbidRemoteReferenceToLocal]).rawValue])
        return IndexedHLSMedia(asset: asset, port: port, server: origin, video: video, audio: audio, videoIndex: vi, audioIndex: ai)
      }, onCancel: { video.cancel(); audio.cancel() })
    } catch { server?.cancel(); video.cancel(); audio.cancel(); throw error }
  }
  func cancel() { asset.cancelLoading(); server.cancel(); video.cancel(); audio.cancel() }
  func testAudioSample() async throws -> Data {
    guard CommandLine.arguments.contains("--ui-smoke"), let segment = audioIndex.segments.first,
      segment.length <= 1_048_576 else { throw MTVError.message("音频验证样本超出范围") }
    let chunk = try await audio.fetch(offset: segment.offset, count: segment.length)
    return audioIndex.initialization + chunk.data
  }
  func statistics() async -> [String: Int] {
    let v = await video.statistics(), a = await audio.statistics()
    return ["videoRequests": v.requests, "videoBytes": v.received, "audioRequests": a.requests, "audioBytes": a.received,
      "videoPrefixHits": v.prefixHits, "audioPrefixHits": a.prefixHits,
      "videoSegments": videoIndex.segments.count, "audioSegments": audioIndex.segments.count]
  }
  deinit { server.cancel(); video.cancel(); audio.cancel() }
}

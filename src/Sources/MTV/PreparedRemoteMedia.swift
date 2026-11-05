import AVFoundation
import Foundation
import MTVCore

struct RemotePreparationFailure: Error, LocalizedError, Sendable {
  let message: String
  let observations: [RemoteResponseObservation]
  var errorDescription: String? { message }
}

/// Resources remain alive for the entire playback; composition copies compressed tracks without transcoding.
final class PreparedRemoteMedia: @unchecked Sendable {
  let asset: AVAsset
  let resources: [RemoteHeaderStream]
  let primaryURL: URL
  let indexedHLS: IndexedHLSMedia?
  let playablePreparation: String
  private init(asset: AVAsset, resources: [RemoteHeaderStream], indexedHLS: IndexedHLSMedia? = nil, playablePreparation: String = "eager") {
    self.asset = asset; self.resources = resources; self.indexedHLS = indexedHLS
    self.playablePreparation = playablePreparation
    primaryURL = indexedHLS?.asset.url ?? resources[0].asset.url
  }
  func cancel() { for resource in resources { resource.cancel() }; indexedHLS?.cancel() }
  func preparationStatistics() async -> [String: Int] {
    var result: [String: Int] = [:]
    for (index, resource) in resources.enumerated() {
      for (key, value) in await resource.statistics() { result["\(index == 0 ? "video" : "audio").\(key)"] = value }
    }
    return result
  }
  deinit { cancel() }

  @MainActor static func prepare(video: RemotePlaybackRequest, audio: RemotePlaybackRequest?, indexed: Bool = false,
    onResources: ([RemoteHeaderStream]) -> Void = { _ in }) async throws -> PreparedRemoteMedia {
    if indexed {
      guard let audio else { throw MTVError.message("索引播放需要独立音轨") }
      let result = try await IndexedHLSMedia.prepare(video: video, audio: audio)
      return PreparedRemoteMedia(asset: result.asset, resources: [], indexedHLS: result, playablePreparation: "indexed-fmp4")
    }
    let videoStream = try RemoteHeaderStream(video)
    let audioStream = try audio.map(RemoteHeaderStream.init)
    let resources = [videoStream] + (audioStream.map { [$0] } ?? [])
    onResources(resources)
    do {
      return try await withTaskCancellationHandler(operation: {
        if let audioStream {
          guard let videoTrack = try await videoStream.asset.loadTracks(withMediaType: .video).first,
            let audioTrack = try await audioStream.asset.loadTracks(withMediaType: .audio).first else {
            throw MTVError.message("分轨片源缺少所声明的视频或音频轨道")
          }
          let videoRange = try await videoTrack.load(.timeRange)
          let audioRange = try await audioTrack.load(.timeRange)
          let timing = try SplitPlaybackTiming(videoStart: videoRange.start.seconds, videoDuration: videoRange.duration.seconds,
            audioStart: audioRange.start.seconds, audioDuration: audioRange.duration.seconds)
          try Task.checkCancellation()
          let composition = AVMutableComposition()
          guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
            let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MTVError.message("无法建立分轨播放时间轴")
          }
          try picture.insertTimeRange(videoRange, of: videoTrack, at: CMTime(seconds: timing.videoOffset, preferredTimescale: 60000))
          try sound.insertTimeRange(audioRange, of: audioTrack, at: CMTime(seconds: timing.audioOffset, preferredTimescale: 60000))
          picture.preferredTransform = try await videoTrack.load(.preferredTransform)
          guard try await composition.load(.isPlayable) else { throw MTVError.message("系统无法播放此分轨组合") }
          try Task.checkCancellation()
          return PreparedRemoteMedia(asset: composition, resources: resources, playablePreparation: "composition")
        }
        let benchmark = CommandLine.arguments.contains("--ui-smoke") && CommandLine.arguments.contains("--playback-benchmark-only")
        let eagerControl = benchmark && CommandLine.arguments.contains("--benchmark-eager-playable")
        let deferredControl = benchmark && CommandLine.arguments.contains("--benchmark-defer-playable")
        let deferPlayable = !eagerControl && (deferredControl || video.carriesNativeSession)
        if !deferPlayable {
          guard try await videoStream.asset.load(.isPlayable) else { throw MTVError.message("系统无法播放此网络片源") }
        }
        try Task.checkCancellation()
        return PreparedRemoteMedia(asset: videoStream.asset, resources: resources, playablePreparation: deferPlayable ? "playerItem" : "eager")
      }, onCancel: { for resource in resources { resource.cancel() } })
    } catch {
      var detail: String?
      var observations: [RemoteResponseObservation] = []
      for (index, resource) in resources.enumerated() {
        for var observation in await resource.observations() {
          observation.role = index == 0 ? "video" : "audio"; observations.append(observation)
        }
        if detail == nil, let message = await resource.failureMessage() { detail = message }
      }
      for resource in resources { resource.cancel() }
      if Task.isCancelled { throw CancellationError() }
      throw RemotePreparationFailure(message: detail ?? error.localizedDescription, observations: observations)
    }
  }
}

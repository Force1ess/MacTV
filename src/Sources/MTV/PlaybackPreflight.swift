import AVFoundation
import Foundation
import MTVCore

struct PlaybackSelection {
  let engine: PlaybackEngineChoice
  let asset: AVURLAsset?
  let reason: String
}
enum VLCContainerReader: Int32, Sendable { case native = 0, avformat = 1 }
struct VLCContainerPlan: Sendable {
  let reader: VLCContainerReader
  let editSegmentCount: Int?
  let reason: String
  static let standard = Self(reader: .native, editSegmentCount: nil, reason: "默认容器读取")
}

enum PlaybackPreflight {
  static func vlcContainerPlan(_ url: URL) async throws -> VLCContainerPlan {
    guard url.isFileURL, ["mp4", "mov", "m4v"].contains(url.pathExtension.lowercased()) else { return .standard }
    let asset = AVURLAsset(url: url)
    return try await withTaskCancellationHandler(operation: {
      do {
        if try await asset.load(.hasProtectedContent) { return VLCContainerPlan(reader: .native, editSegmentCount: nil, reason: "受保护内容，未改变容器读取") }
        let tracks = try await asset.load(.tracks)
        guard tracks.count <= 32 else { return VLCContainerPlan(reader: .native, editSegmentCount: nil, reason: "轨道数量超出编辑表检查范围，保留默认读取") }
        var count = 0
        for track in tracks where track.mediaType == .video || track.mediaType == .audio {
          let segments = try await track.load(.segments)
          try Task.checkCancellation()
          guard segments.count <= 4096 else { return VLCContainerPlan(reader: .native, editSegmentCount: nil, reason: "编辑表超出检查范围，保留默认读取") }
          count = max(count, segments.count)
        }
        return VLCContainerPlan(reader: count > 1 ? .avformat : .native, editSegmentCount: count,
          reason: count > 1 ? "多段编辑兼容读取 · 接缝音频可能短暂异常，可选择系统引擎" : "单段时间线 · 默认容器读取")
      } catch {
        if Task.isCancelled || error is CancellationError { throw CancellationError() }
        let value = error as NSError
        return VLCContainerPlan(reader: .native, editSegmentCount: nil, reason: "编辑表未识别，保留默认读取（\(value.domain) \(value.code)）")
      }
    }, onCancel: { asset.cancelLoading() })
  }
  static func checkedURL(_ url: URL, boundary: URL?) async throws -> URL {
    try Task.checkCancellation()
    let resolved = try await Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let resolved = url.isFileURL ? url.resolvingSymlinksInPath() : url
      if resolved.isFileURL, let root = boundary?.resolvingSymlinksInPath().path,
        resolved.path != root && !resolved.path.hasPrefix(root + "/")
      {
        throw MTVError.message("媒体地址超出所选共享范围")
      }
      return resolved
    }.value
    try Task.checkCancellation()
    return resolved
  }
  static func inspect(_ url: URL) async throws -> PlaybackSelection {
    try Task.checkCancellation()
    if url.isFileURL {
      let header = try await Task.detached(priority: .userInitiated) {
        try Task.checkCancellation()
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: 262144) ?? Data()
      }.value
      try Task.checkCancellation()
      guard !header.isEmpty else { throw MTVError.message("媒体文件为空，无法开始播放") }

      if ContainerInspection.matroskaHeader(header) {
        if ContainerInspection.dolbyVisionProfile(header) == 5, MPVPlaybackEngine.isAvailable {
          return PlaybackSelection(engine:.mpv,asset:nil,reason:"杜比视界Profile 5 · MPV GPU色彩转换")
        }
        guard MPVPlaybackEngine.isAvailable else { throw MTVError.message("本地播放器组件缺失，请重新安装MTV。") }
        return PlaybackSelection(engine: .mpv, asset: nil, reason: "Matroska 容器 · MPV")
      }
    }
    let asset = AVURLAsset(url: url)
    let playable = try await withTaskCancellationHandler(
      operation: {
        try await asset.load(.isPlayable)
      }, onCancel: { asset.cancelLoading() })
    try Task.checkCancellation()
    if playable {
      // Reuse the inspected asset to avoid fetching a remote stream twice.
      return PlaybackSelection(engine: .system, asset: asset, reason: "系统报告此片源可播放")
    }
    asset.cancelLoading()
    guard url.isFileURL, MPVPlaybackEngine.isAvailable else { throw MTVError.message("当前视频格式无法播放。") }
    return PlaybackSelection(engine: .mpv, asset: nil, reason: "本地影片格式 · MPV")
  }
}

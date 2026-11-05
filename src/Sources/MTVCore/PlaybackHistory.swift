import Foundation

public struct PlaybackHistoryContext: Codable, Identifiable, Sendable, Equatable {
  public let mediaID: String
  public let sourceID: String
  public let title: String
  public let subtitle: String
  public let sourceTitle: String
  public let poster: String?
  public let reference: String?
  public let collectionReference: String?
  public let librarySource: LibrarySourceSelection?
  public var id: String { PlaybackResumeStore.identity(for: mediaID, source: sourceID) ?? "" }
  public init(mediaID: String, sourceID: String, title: String, subtitle: String = "", sourceTitle: String,
    poster: String? = nil, reference: String? = nil, collectionReference: String? = nil, librarySource: LibrarySourceSelection? = nil) throws {
    self.mediaID = mediaID; self.sourceID = sourceID; self.title = title; self.subtitle = subtitle
    self.sourceTitle = sourceTitle; self.poster = poster; self.reference = reference; self.librarySource = librarySource
    self.collectionReference = collectionReference
    try validate()
  }
  public func validate() throws {
    guard !id.isEmpty, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      title.utf8.count <= 2048, subtitle.utf8.count <= 2048, !sourceTitle.isEmpty, sourceTitle.utf8.count <= 1024 else { throw MTVError.message("观看记录描述无效") }
    if sourceID == "local" {
      guard let librarySource, (librarySource.path == nil) != (librarySource.smbProfileID == nil), reference == nil, collectionReference == nil else { throw MTVError.message("观看记录缺少影片库来源") }
      try librarySource.validate()
    } else {
      guard sourceID.utf8.count <= 128, sourceID.range(of: #"^[a-z0-9]+([.-][a-z0-9]+)*$"#, options: .regularExpression) != nil,
        librarySource == nil, stableSavedReference(mediaID, maximum: 8192), let reference, stableSavedReference(reference),
        collectionReference == nil || stableSavedReference(collectionReference!) else { throw MTVError.message("模块观看记录需要稳定引用，不能保存播放链接") }
    }
    if let poster {
      guard poster.utf8.count <= 4096, let url = URL(string: poster), url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw MTVError.message("观看记录图片地址无效") }
      if url.isFileURL {
        guard let path = librarySource?.path,
          url.standardizedFileURL.path.hasPrefix(path == "/" ? "/" : path + "/") else { throw MTVError.message("观看记录不保存共享挂载或来源外文件图片") }
      } else {
        guard SMBCachedArtwork.isLocalReference(url) || url.scheme == "https" && url.host != nil && (url.port == nil || url.port == 443) else { throw MTVError.message("观看记录图片协议无效") }
      }
    }
  }
  public func replacingPoster(_ poster: String?) throws -> Self {
    try Self(mediaID: mediaID, sourceID: sourceID, title: title, subtitle: subtitle, sourceTitle: sourceTitle,
      poster: poster, reference: reference, collectionReference: collectionReference, librarySource: librarySource)
  }
}

private func stableSavedReference(_ value: String, maximum: Int = 512) -> Bool {
  !value.isEmpty && value.utf8.count <= maximum && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
    && !["http:", "https:", "file:"].contains(where: { value.lowercased().hasPrefix($0) })
    && value.unicodeScalars.allSatisfy { $0.value >= 32 && $0.value != 127 }
}

public struct PlaybackHistoryEntry: Identifiable, Sendable {
  public let context: PlaybackHistoryContext
  public let progress: PlaybackResumeRecord
  public var id: String { context.id }
}

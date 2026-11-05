import Foundation

public struct SMBIndexedMedia: Codable {
  public let path: String
  public let seriesRoot: String?
  public let description: MediaItem
  public var poster: SMBCachedArtwork? = nil
  public var seriesPoster: SMBCachedArtwork? = nil
}
public struct SMBLibrarySnapshot: Codable {
  public let schema: Int
  public let profileID: UUID
  public let namespace: String
  public let selectionAddress: String
  public let scannedAt: Date
  public let records: [SMBIndexedMedia]
  public var artworkSkippedCount: Int? = nil
  public func offlineItems() -> [MediaItem] {
    records.map {
      var item = $0.description
      item.url = nil
      item.poster = try? $0.poster?.url(namespace: namespace, profileID: profileID).absoluteString
      item.localMetadata?.seriesPoster = try? $0.seriesPoster?.url(
        namespace: namespace, profileID: profileID
      ).absoluteString
      item.localMetadata?.sourceReachable = false
      return item
    }
  }
  public func binding(profile: SMBProfile, mount: URL) throws -> [MediaItem] {
    guard profileID == profile.id, namespace == (try SMBMediaIdentity.namespace(profile)),
      selectionAddress == profile.address
    else { throw MTVError.message("NAS 缓存不属于当前连接或目录") }
    let items = try records.map { record -> MediaItem in
      var item = record.description
      item.url = try SMBMediaIdentity.fileURL(relativePath: record.path, mount: mount)
        .absoluteString
      item.poster = try record.poster?.url(namespace: namespace, profileID: profileID)
        .absoluteString
      if let series = record.seriesRoot {
        item.localMetadata?.seriesRoot = try SMBMediaIdentity.fileURL(
          relativePath: series, mount: mount
        ).path
      }
      item.localMetadata?.seriesPoster = try record.seriesPoster?.url(
        namespace: namespace, profileID: profileID
      ).absoluteString
      // Artwork references read only MTV's cache; shared files require a fresh scan.
      item.localMetadata?.sourceReachable = nil
      return item
    }
    let mapped = try SMBMediaIdentity.remap(items, profile: profile, mount: mount)
    guard mapped.map(\.id) == records.map({ $0.description.id }) else {
      throw MTVError.message("NAS 缓存身份不一致")
    }
    guard
      zip(mapped, records).allSatisfy({
        $0.0.localMetadata?.seriesIdentity == $0.1.description.localMetadata?.seriesIdentity
      })
    else { throw MTVError.message("NAS 缓存系列身份不一致") }
    return mapped
  }
}

public actor SMBLibraryIndexStore {
  public let root: URL
  private let artwork: SMBArtworkCache
  public init(
    root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/MTV/Library/SMBIndexes"),
    artwork: SMBArtworkCache = SMBArtworkCache()
  ) {
    self.root = root
    self.artwork = artwork
  }
  public func load(profile: SMBProfile) throws -> SMBLibrarySnapshot? {
    let file = root.appendingPathComponent(profile.id.uuidString.lowercased() + ".json")
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 25_000_000 else {
      throw MTVError.message("NAS 索引超过大小限制")
    }
    let snapshot = try JSONDecoder().decode(SMBLibrarySnapshot.self, from: Data(contentsOf: file))
    guard snapshot.schema == 1, snapshot.profileID == profile.id else {
      throw MTVError.message("NAS 索引格式无效")
    }
    guard snapshot.namespace == (try SMBMediaIdentity.namespace(profile)),
      snapshot.selectionAddress == profile.address
    else { return nil }
    try validate(snapshot, profile: profile)
    return snapshot
  }
  @discardableResult public func save(
    _ items: [MediaItem], profile: SMBProfile, mount: URL,
    scannedAt: Date = Date()
  ) async throws -> Bool {
    try await saveDetailed(items, profile: profile, mount: mount, scannedAt: scannedAt).written
  }
  public struct SaveResult {
    public let written: Bool
    public let artworkSkipped: Int
  }
  public func saveDetailed(
    _ items: [MediaItem], profile: SMBProfile, mount: URL,
    scannedAt: Date = Date(), verifying share: MountedSMBShare? = nil
  ) async throws -> SaveResult {
    try Task.checkCancellation()
    if let share {
      guard share.mount.standardizedFileURL.path == mount.standardizedFileURL.path else { throw SMBFailure.mountChanged(3) }
      try share.validateCurrentMount()
    }
    guard items.count <= 10_000 else { throw MTVError.message("NAS 索引条目过多") }
    let previous = try? load(profile: profile)
    if let previous, previous.scannedAt > scannedAt {
      return SaveResult(written: false, artworkSkipped: previous.artworkSkippedCount ?? 0)
    }
    let namespace = try SMBMediaIdentity.namespace(profile)
    var imports: [String: (SMBCachedArtwork?, Bool)] = [:]
    var skipped = 0
    func importImage(_ address: String?, previous: SMBCachedArtwork?) async throws -> SMBCachedArtwork? {
      guard let address, let url = URL(string: address) else { return nil }
      if let previous,
        (try? previous.url(namespace: namespace, profileID: profile.id).absoluteString) == address
      {
        return previous
      }
      if let result = imports[address] { return result.0 }
      do {
        guard url.isFileURL else { throw MTVError.message("原始 NAS 封面不是共享文件") }
        let reference = try await artwork.cache(url, profile: profile, mount: mount, verifying: share)
        imports[address] = (reference, true)
        return reference
      } catch {
        if error is CancellationError || (error as? SMBFailure)?.stage == .mountValidation { throw error }
        imports[address] = (nil, false)
        skipped += 1
        return nil
      }
    }
    let previousRecords = Dictionary(
      (previous?.records ?? []).map { ($0.description.id, $0) },
      uniquingKeysWith: { first, _ in first })
    var records: [SMBIndexedMedia] = []
    for original in items {
      try Task.checkCancellation()
      guard let raw = original.url, let url = URL(string: raw) else {
        throw MTVError.message("NAS 条目没有当前文件地址")
      }
      let poster = try await importImage(
        original.poster, previous: previousRecords[original.id]?.poster)
      let seriesPoster = try await importImage(
        original.localMetadata?.seriesPoster, previous: previousRecords[original.id]?.seriesPoster)
      let path = try SMBMediaIdentity.relativePath(url, mount: mount)
      var item = original
      let series = try item.localMetadata?.seriesRoot.map {
        try SMBMediaIdentity.relativePath(URL(fileURLWithPath: $0), mount: mount)
      }
      item.url = nil
      item.poster = nil
      item.localMetadata?.seriesPoster = nil
      if let series { item.localMetadata?.seriesRoot = "smb-relative:" + series }
      var record = SMBIndexedMedia(path: path, seriesRoot: series, description: item)
      record.poster = poster
      record.seriesPoster = seriesPoster
      records.append(record)
    }
    var snapshot = SMBLibrarySnapshot(
      schema: 1, profileID: profile.id,
      namespace: try SMBMediaIdentity.namespace(profile), selectionAddress: profile.address,
      scannedAt: scannedAt, records: records)
    snapshot.artworkSkippedCount = skipped
    try Task.checkCancellation()
    try validate(snapshot, profile: profile)
    if let previous = try? load(profile: profile), previous.scannedAt > scannedAt {
      return SaveResult(written: false, artworkSkipped: skipped)
    }
    let data = try JSONEncoder().encode(snapshot)
    guard data.count <= 25_000_000 else { throw MTVError.message("NAS 索引超过大小限制") }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent(profile.id.uuidString.lowercased() + ".json")
    try share?.validateCurrentMount()
    try data.write(to: file, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    return SaveResult(written: true, artworkSkipped: skipped)
  }
  private func validate(_ snapshot: SMBLibrarySnapshot, profile: SMBProfile) throws {
    guard snapshot.records.count <= 10_000, snapshot.scannedAt.timeIntervalSince1970.isFinite,
      Set(snapshot.records.map { $0.description.id }).count == snapshot.records.count
    else { throw MTVError.message("NAS 索引条目无效") }
    let validationRoot = URL(
      fileURLWithPath: "/mtv-cache-validation/" + profile.id.uuidString.lowercased())
    for record in snapshot.records {
      _ = try record.poster?.url(namespace: snapshot.namespace, profileID: snapshot.profileID)
      _ = try record.seriesPoster?.url(namespace: snapshot.namespace, profileID: snapshot.profileID)
      let item = record.description
      guard !record.path.isEmpty, item.source == "local", !item.isFolder, !item.isLibraryCollection,
        item.url == nil, item.poster == nil, item.localMetadata?.seriesPoster == nil,
        item.metadataAttribution == nil, item.title.count <= 4096,
        item.overview.utf8.count <= 2_000_000,
        record.seriesRoot.map({ item.localMetadata?.seriesRoot == "smb-relative:" + $0 })
          ?? (item.localMetadata?.seriesRoot == nil)
      else { throw MTVError.message("NAS 缓存包含临时地址或无效描述") }
    }
    _ = try snapshot.binding(profile: profile, mount: validationRoot)
  }
}

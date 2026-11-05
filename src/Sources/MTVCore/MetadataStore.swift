import Foundation

public enum MetadataMatchOrigin: String, Codable { case manual, automatic }
public struct MetadataMatch: Codable, Hashable {
  public let targetID: String
  public let candidate: MetadataCandidate
  public let selectedAt: Date
  public var origin: MetadataMatchOrigin? = nil
}

/// Only MTV's cache is written; original media and NFO are never changed.
public struct MetadataStore {
  public let file: URL
  public init(
    file: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/MTV/Library/matches.json")
  ) { self.file = file }
  private var localizedSeriesFile: URL {
    file.deletingPathExtension().appendingPathExtension("zh-series.json")
  }
  public func loadLocalizedSeries() throws -> [Int: MetadataCandidate] {
    let url = localizedSeriesFile
    guard FileManager.default.fileExists(atPath: url.path) else { return [:] }
    guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 5_000_000 else {
      throw MTVError.message("Localized series cache is too large")
    }
    let records = try JSONDecoder().decode([Int: MetadataCandidate].self, from: Data(contentsOf: url))
    try Self.validateLocalizedSeries(records)
    return records
  }
  public func saveLocalizedSeries(_ records: [Int: MetadataCandidate]) throws {
    try Self.validateLocalizedSeries(records)
    let bytes = try JSONEncoder().encode(records)
    guard bytes.count <= 5_000_000 else { throw MTVError.message("Localized series cache is too large") }
    let url = localizedSeriesFile
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try bytes.write(to: url, options: .atomic)
  }
  private static func validateLocalizedSeries(_ records: [Int: MetadataCandidate]) throws {
    guard records.count <= 10_000 else { throw MTVError.message("Too many localized series") }
    for (id, candidate) in records {
      guard id > 0, candidate.provider == .tmdb, candidate.kind == .series, containsChinese(candidate.title) else {
        throw MTVError.message("Invalid localized series record")
      }
      try candidate.validate()
    }
  }
  public func load() throws -> [String: MetadataMatch] {
    guard FileManager.default.fileExists(atPath: file.path) else { return [:] }
    guard (try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 5_000_000 else {
      throw MTVError.message("资料库匹配缓存过大")
    }
    let records = try JSONDecoder().decode(
      [String: MetadataMatch].self, from: Data(contentsOf: file))
    guard records.count <= 10_000 else { throw MTVError.message("资料库匹配数量超过限制") }
    for (id, record) in records {
      guard id == record.targetID else { throw MTVError.message("资料库匹配标识不一致") }
      try record.candidate.validate()
    }
    return records
  }
  @discardableResult public func set(
    targetID: String, candidate: MetadataCandidate?, origin: MetadataMatchOrigin = .manual
  ) throws
    -> [String: MetadataMatch]
  {
    var records = try load()
    if let candidate {
      try candidate.validate()
      var match = MetadataMatch(
        targetID: targetID, candidate: candidate, selectedAt: Date())
      match.origin = origin
      records[targetID] = match
    } else {
      records.removeValue(forKey: targetID)
    }
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(records)
    guard records.count <= 10_000, data.count <= 5_000_000 else {
      throw MTVError.message("资料库匹配缓存超过限制")
    }
    try data.write(to: file, options: .atomic)
    return records
  }
  public func insertAutomatic(targetID: String, candidate: MetadataCandidate) throws -> Bool {
    guard try load()[targetID] == nil else { return false }
    _ = try set(targetID: targetID, candidate: candidate, origin: .automatic)
    return true
  }
  public func backupForMaintenance() throws -> URL? {
    guard FileManager.default.fileExists(atPath: file.path) else { return nil }
    _ = try load()
    return try PrivateDataBackup.write(Data(contentsOf: file), in: file.deletingLastPathComponent().appendingPathComponent("backups"),
      label: "影片匹配", prefix: "matches-", suffix: ".json").url
  }
  public static func apply(_ records: [String: MetadataMatch], to files: [MediaItem],
    localizedSeries: [Int: MetadataCandidate] = [:]) -> [MediaItem]
  {
    let protectedSeries = Set(
      files.filter { $0.localMetadata?.hasSidecar != false }.compactMap {
        LibraryCatalog.seriesIdentity($0).map { "mtv:series:" + $0 }
      })
    return files.map { original in
      var item = original
      if let identity = LibraryCatalog.seriesIdentity(original),
        let record = records["mtv:series:" + identity], record.candidate.kind == .series,
        record.origin != .automatic || !protectedSeries.contains(record.targetID)
      {
        item.localMetadata?.seriesIdentity = identity
        let translated = record.candidate.provider == .tvmaze ? localizedSeries[record.candidate.externalID] : nil
        item.localMetadata?.seriesTitle = translated?.title ?? displayTitle(record.candidate, local: original.localMetadata?.seriesTitle)
        let overview = translated.flatMap { containsChinese($0.overview) ? $0.overview : nil } ?? record.candidate.overview
        if !overview.isEmpty {
          item.localMetadata?.seriesOverview = overview
        }
        if let poster = record.candidate.poster { item.localMetadata?.seriesPoster = poster }
        item.metadataAttribution = record.candidate.attribution.absoluteString
      } else if original.localMetadata?.episode == nil,
        let record = records[original.id], record.candidate.kind == .movie,
        record.origin != .automatic || original.localMetadata?.hasSidecar == false
      {
        item.title = displayTitle(record.candidate, local: original.title)
        if record.origin != .automatic { item.localMetadata?.isExtra = false }
        if !record.candidate.overview.isEmpty { item.overview = record.candidate.overview }
        if let poster = record.candidate.poster { item.poster = poster }
        if item.localMetadata == nil { item.localMetadata = LocalMediaMetadata() }
        item.localMetadata?.movieTMDBID = record.candidate.provider == .tmdb ? record.candidate.externalID : nil
        if let year = record.candidate.year { item.localMetadata?.year = year }
        item.subtitle = record.candidate.year.map(String.init) ?? item.subtitle
        item.metadataAttribution = record.candidate.attribution.absoluteString
      }
      return item
    }
  }
  public static var prefersChinese: Bool {
    (Bundle.main.preferredLocalizations.first ?? Locale.preferredLanguages.first ?? "").hasPrefix("zh")
  }
  public static func containsChinese(_ title: String) -> Bool {
    title.range(of: #"\p{Han}"#, options: .regularExpression) != nil
      && title.range(of: #"[\p{Hiragana}\p{Katakana}]"#, options: .regularExpression) == nil
  }
  private static func displayTitle(_ candidate: MetadataCandidate, local: String?) -> String {
    guard prefersChinese else { return candidate.title }
    let titles = [candidate.title, candidate.originalTitle].compactMap { $0 }
      + (candidate.officialAliases ?? []) + [local].compactMap { $0 }
    return titles.first(where: containsChinese) ?? candidate.title
  }
}

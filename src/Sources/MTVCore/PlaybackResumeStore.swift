import Foundation

public struct PlaybackResumeRecord: Codable, Sendable {
  public let position: Double
  public let duration: Double?
  public let updatedAt: Date?
  public var resumablePosition: Double {
    guard position > 5 else { return 0 }
    if let duration, duration <= 30 || position >= duration - 15 { return 0 }
    return position
  }
}

public struct PlaybackResumeStore {
  private let defaults: UserDefaults
  private let testDomain: String?
  public init() {
    defaults = .standard
    testDomain = nil
  }
  private init(defaults: UserDefaults, testDomain: String) {
    self.defaults = defaults
    self.testDomain = testDomain
  }
  public static func isolated(scope: UUID = UUID()) -> PlaybackResumeStore {
    let domain = "local.mtv.preview.resume-fixture." + scope.uuidString.lowercased()
    return PlaybackResumeStore(defaults: UserDefaults(suiteName: domain)!, testDomain: domain)
  }
  public static func identity(for id: String, source: String) -> String? {
    guard !id.isEmpty, id.utf8.count <= 8192, !source.isEmpty, source.utf8.count <= 256,
      let bytes = try? JSONEncoder().encode([source, id]) else { return nil }
    return bytes.base64EncodedString()
  }
  private func key(for id: String, source: String) -> String? {
    Self.identity(for: id, source: source).map { "resume.v2." + $0 }
  }
  public func record(for id: String, source: String = "local") -> PlaybackResumeRecord? {
    guard let key = key(for: id, source: source) else { return nil }
    if defaults.object(forKey: key) != nil {
      guard let bytes = defaults.data(forKey: key), bytes.count <= 1024,
        let record = try? JSONDecoder().decode(PlaybackResumeRecord.self, from: bytes),
        record.position.isFinite, record.position > 0,
        record.duration == nil || (record.duration!.isFinite && record.duration! > 0)
      else { return nil }
      return record
    }
    // Old keys did not identify the plugin. They are safe to reuse only for local media.
    guard source == "local" else { return nil }
    let value = defaults.double(forKey: "resume." + id)
    return value.isFinite && value > 0 ? PlaybackResumeRecord(position: value, duration: nil, updatedAt: nil) : nil
  }
  public func position(for id: String, source: String = "local") -> Double {
    record(for: id, source: source)?.position ?? 0
  }
  public func save(_ seconds: Double, for id: String, source: String = "local", duration: Double? = nil) {
    guard let key = key(for: id, source: source), seconds.isFinite, seconds > 0 else { return }
    let length = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    let record = PlaybackResumeRecord(position: seconds, duration: length, updatedAt: Date())
    guard let bytes = try? JSONEncoder().encode(record) else { return }
    defaults.set(bytes, forKey: key)
  }
  public func removeTestDomain() {
    if let testDomain { defaults.removePersistentDomain(forName: testDomain) }
  }
  private struct WatchlistDocument: Codable { let schema: Int; var contexts: [PlaybackHistoryContext] }
  public func watchlist() throws -> [PlaybackHistoryContext] {
    guard defaults.object(forKey: "watchlist.v1") != nil else { return [] }
    guard let bytes = defaults.data(forKey: "watchlist.v1"), bytes.count <= 262_144 else { throw MTVError.message("待看片单过大或格式无效；原记录已保留") }
    let value = try JSONDecoder().decode(WatchlistDocument.self, from: bytes)
    guard value.schema == 1, value.contexts.count <= 50, Set(value.contexts.map(\.id)).count == value.contexts.count else { throw MTVError.message("待看片单格式无效；原记录已保留") }
    for context in value.contexts { try context.validate() }
    return value.contexts
  }
  public func addToWatchlist(_ context: PlaybackHistoryContext) throws {
    try context.validate()
    var contexts = try watchlist()
    if let index = contexts.firstIndex(where: { $0.id == context.id }) { contexts[index] = context }
    else {
      guard contexts.count < 50 else { throw MTVError.message("待看片单最多保存50项，请先移除不用的条目") }
      contexts.insert(context, at: 0)
    }
    try saveWatchlist(contexts)
  }
  public func removeFromWatchlist(_ id: String) throws {
    var contexts = try watchlist(); contexts.removeAll { $0.id == id }
    try saveWatchlist(contexts)
  }
  private func saveWatchlist(_ contexts: [PlaybackHistoryContext]) throws {
    let bytes = try JSONEncoder().encode(WatchlistDocument(schema: 1, contexts: contexts))
    guard bytes.count <= 262_144 else { throw MTVError.message("待看片单描述超过大小限制；原记录已保留") }
    defaults.set(bytes, forKey: "watchlist.v1")
  }
  private struct HistoryDocument: Codable { let schema: Int; var contexts: [PlaybackHistoryContext] }
  private func historyDocument() throws -> HistoryDocument {
    guard defaults.object(forKey: "watch-history.v1") != nil else { return HistoryDocument(schema: 1, contexts: []) }
    guard let bytes = defaults.data(forKey: "watch-history.v1"), bytes.count <= 262_144 else { throw MTVError.message("观看列表记录过大或格式无效") }
    let value = try JSONDecoder().decode(HistoryDocument.self, from: bytes)
    guard value.schema == 1, value.contexts.count <= 20, Set(value.contexts.map(\.id)).count == value.contexts.count else { throw MTVError.message("观看列表格式无效") }
    for context in value.contexts { try context.validate() }
    return value
  }
  public func recent() throws -> [PlaybackHistoryEntry] {
    try historyDocument().contexts.compactMap { context in
      guard let progress = record(for: context.mediaID, source: context.sourceID), progress.resumablePosition > 0 else { return nil }
      return PlaybackHistoryEntry(context: context, progress: progress)
    }.sorted {
      let first = $0.progress.updatedAt ?? .distantPast, second = $1.progress.updatedAt ?? .distantPast
      return first == second ? $0.id < $1.id : first > second
    }
  }
  public func remember(_ context: PlaybackHistoryContext) throws {
    try context.validate()
    var document = try historyDocument()
    document.contexts.removeAll { $0.id == context.id }
    if (record(for: context.mediaID, source: context.sourceID)?.resumablePosition ?? 0) > 0 { document.contexts.insert(context, at: 0) }
    document.contexts = Array(document.contexts.prefix(20))
    let data = try JSONEncoder().encode(document)
    guard data.count <= 262_144 else { throw MTVError.message("观看列表描述超过大小限制") }
    defaults.set(data, forKey: "watch-history.v1")
  }
  public func forgetHistory(_ id: String) throws {
    var document = try historyDocument(); document.contexts.removeAll { $0.id == id }
    defaults.set(try JSONEncoder().encode(document), forKey: "watch-history.v1")
  }
  private func historyResetSnapshot() throws -> Data {
    guard let value = defaults.object(forKey: "watch-history.v1") else { throw MTVError.message("目前没有需要重建的观看列表") }
    let data = try PropertyListSerialization.data(fromPropertyList: ["value": value], format: .xml, options: 0)
    guard data.count <= 1_048_576 else { throw MTVError.message("观看记录过大，未执行自动清除；原数据保留") }
    return data
  }
  public func reviewHistoryReset() throws -> PlaybackHistoryResetReview {
    let snapshot = try historyResetSnapshot()
    let count = try? historyDocument().contexts.count
    return PlaybackHistoryResetReview(snapshot: snapshot, recordCount: count)
  }
  /// Call on the same serialized owner as normal history mutations. A changed
  /// list or backup must be reviewed again; resume keys are never removed.
  public func commitHistoryReset(_ backup: PlaybackHistoryResetBackup) throws {
    guard try historyResetSnapshot() == backup.snapshot else { throw MTVError.message("观看列表已变化，请重新审阅；未清除新记录") }
    try backup.verify()
    guard try historyResetSnapshot() == backup.snapshot else { throw MTVError.message("观看列表已变化，请重新审阅；未清除新记录") }
    defaults.removeObject(forKey: "watch-history.v1")
  }
}

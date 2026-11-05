import Foundation

public struct PlaybackHistoryResetReview: Sendable {
  let snapshot: Data
  public let recordCount: Int?
  public var byteCount: Int { snapshot.count }
  public var isDamaged: Bool { recordCount == nil }
  /// Does not mutate preferences. May run off the UI thread.
  public func writeBackup(in directory: URL) throws -> PlaybackHistoryResetBackup {
    PlaybackHistoryResetBackup(file: try .write(snapshot, in: directory,
      label: "观看记录", prefix: "watch-history-", suffix: ".plist"))
  }
}
public struct PlaybackHistoryResetBackup: Sendable {
  let file: PrivateDataBackup
  public var url: URL { file.url }
  var snapshot: Data { file.snapshot }
  func verify() throws { try file.verify() }
}

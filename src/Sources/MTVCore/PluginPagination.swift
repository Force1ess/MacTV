import Foundation

public enum PluginPagination {
  /// Empty filtered pages can legitimately precede videos. Only an actual
  /// nonempty duplicate page proves that appending this result made no progress.
  public static func mayAdvance(returnedIDs: [String], knownIDs: Set<String>) -> Bool {
    returnedIDs.isEmpty || returnedIDs.contains { !knownIDs.contains($0) }
  }
}

import Foundation

public enum AudioTrackPreference {
  public static func isOriginal(_ title: String) -> Bool {
    title.range(of: #"\boriginal\b"#, options: [.regularExpression, .caseInsensitive]) != nil
      || title.contains("原声") || title.contains("原音")
  }
  public static func isCommentary(_ title: String) -> Bool {
    let value = title.lowercased()
    return value.contains("commentary") || value.contains("audio description")
      || value.contains("descriptive audio") || title.contains("导演评论") || title.contains("解说音轨")
  }
}

import Foundation

/// Identify supplemental files only inside explicitly labelled complete TV
/// releases with a complete set of trusted, numbered same-title siblings.
/// No work titles, provider IDs or physical paths are special-cased.
public enum ReleasePackExtras {
  private struct Title { let group: String, name: String }
  private static func title(_ file: URL) -> Title? {
    let text = MediaRecognition.releaseStem(file)
    guard let expression = try? NSRegularExpression(pattern: #"^\[([^\]]+)\]\[([^\]]+)\]"#),
      let hit = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let group = Range(hit.range(at: 1), in: text), let name = Range(hit.range(at: 2), in: text) else { return nil }
    return Title(group: String(text[group]).lowercased(), name: String(text[name]).trimmingCharacters(in: .whitespaces))
  }
  private static func range(_ folder: URL) -> ClosedRange<Int>? {
    let text = folder.lastPathComponent
    guard let expression = try? NSRegularExpression(pattern: #"(?i)\[(\d{1,3})-(\d{1,3})TV[^\]]*(?:\+SP|\+特典|\+BONUS)[^\]]*\]"#),
      let hit = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      let start = Range(hit.range(at: 1), in: text), let end = Range(hit.range(at: 2), in: text),
      let first = Int(text[start]), let last = Int(text[end]), first > 0, last >= first, last - first < 200 else { return nil }
    return first...last
  }
  public static func apply(_ files: [MediaItem]) -> [MediaItem] {
    struct Anchor { let title: Title; var episodes: Set<Int> }
    var groups: [String: [String: Anchor]] = [:]
    for item in files {
      guard item.source == "local", item.localMetadata?.hasSidecar == true,
        item.localMetadata?.metadataReadFailed != true,
        item.localMetadata?.isExtra != true, let season = item.localMetadata?.season, season > 0,
        let episode = item.localMetadata?.episode,
        let file = item.url.flatMap(URL.init(string:)), file.isFileURL,
        let expected = range(file.deletingLastPathComponent()), expected.contains(episode),
        let sourceTitle = title(file), MediaRecognition.filename(file).seriesTitle != nil else { continue }
      let folder = file.deletingLastPathComponent().path, key = sourceTitle.group + "\n" + sourceTitle.name.lowercased()
      var anchor = groups[folder]?[key] ?? Anchor(title: sourceTitle, episodes: [])
      anchor.episodes.insert(episode); groups[folder, default: [:]][key] = anchor
    }
    return files.map { original in
      guard original.source == "local", original.localMetadata?.hasSidecar == false,
        original.localMetadata?.metadataReadFailed != true, original.localMetadata?.episode == nil,
        original.localMetadata?.year == nil, original.localMetadata?.isExtra != true,
        let file = original.url.flatMap(URL.init(string:)), file.isFileURL,
        let expected = range(file.deletingLastPathComponent()), let candidate = title(file),
        let anchors = groups[file.deletingLastPathComponent().path] else { return original }
      let matches = anchors.values.filter { anchor in
        guard anchor.title.group == candidate.group, Set(expected).isSubset(of: anchor.episodes) else { return false }
        let prefix = anchor.title.name.lowercased() + " "
        return prefix.count >= 7 && candidate.name.lowercased().hasPrefix(prefix)
          && candidate.name.count >= prefix.count + 3
      }
      guard matches.count == 1 else { return original }
      var item = original
      item.localMetadata?.isExtra = true
      item.subtitle = "附加内容"
      return item
    }
  }
}

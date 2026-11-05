import Foundation

/// Reuse cached NFO descriptions when an old link library and a selected disk
/// point at the exact same file. Physical source IDs/URLs stay on the new disk.
public enum LibraryLinkedMetadata {
  public static func apply(_ result: LibraryScanResult, companions: [MediaItem], root: URL) -> LibraryScanResult {
    let boundary = root.resolvingSymlinksInPath().path
    var linked: [String: MediaItem] = [:]
    for item in companions where item.source == "local" && item.localMetadata?.hasSidecar == true {
      guard let url = item.url.flatMap(URL.init(string:)), url.isFileURL,
        FileManager.default.fileExists(atPath: url.path) else { continue }
      let path = url.resolvingSymlinksInPath().path
      guard path.hasPrefix(boundary + "/"), linked[path] == nil else { continue }
      linked[path] = item
    }
    // Copies with an appended download checksum keep their own playback URLs.
    // Reuse descriptions only when the exact, unhashed sibling exists in this
    // selected root; this does not assert byte identity or remove either file.
    func description(for url: URL) -> MediaItem? {
      let path = url.resolvingSymlinksInPath().path
      if let exact = linked[path] { return exact }
      let stem = MediaRecognition.releaseStem(url)
      guard stem != url.deletingPathExtension().lastPathComponent else { return nil }
      let sibling = url.deletingLastPathComponent().appendingPathComponent(stem).appendingPathExtension(url.pathExtension)
      let candidate = sibling.resolvingSymlinksInPath().path
      guard candidate.hasPrefix(boundary + "/"), FileManager.default.fileExists(atPath: sibling.path) else { return nil }
      return linked[candidate]
    }
    let items = result.items.map { current -> MediaItem in
      guard current.localMetadata?.hasSidecar == false,
        let url = current.url.flatMap(URL.init(string:)), url.isFileURL,
        let old = description(for: url), var metadata = old.localMetadata else { return current }
      var item = current
      item.title = old.title; item.subtitle = old.subtitle; item.overview = old.overview
      item.poster = old.poster ?? current.poster
      metadata.sourceReachable = current.localMetadata?.sourceReachable
      metadata.isExtra = current.localMetadata?.isExtra
      // Series roots in KodiLibrary are logical directories, not real files.
      // Their episode files provide the relative depth needed to rebind them.
      if let oldRoot = metadata.seriesRoot, let oldURL = old.url.flatMap(URL.init(string:)),
        oldURL.path.hasPrefix(oldRoot + "/") {
        let depth = oldURL.pathComponents.count - URL(fileURLWithPath: oldRoot).pathComponents.count
        var physicalRoot = url
        if depth > 0 && depth < url.pathComponents.count { for _ in 0..<depth { physicalRoot.deleteLastPathComponent() } }
        if physicalRoot.path == boundary || physicalRoot.path.hasPrefix(boundary + "/") { metadata.seriesRoot = physicalRoot.path }
        else { metadata.seriesRoot = url.deletingLastPathComponent().path }
        metadata.seriesIdentity = nil
      }
      item.localMetadata = metadata
      return item
    }
    // Number-only filenames require a trusted, explicitly numbered sibling
    // from an NFO/link description in the same physical directory. No inference
    // from a franchise title or arbitrary trailing number alone.
    func numbered(_ item: MediaItem) -> (String, Int)? {
      guard let url = item.url.flatMap(URL.init(string:)), url.isFileURL else { return nil }
      let stem = MediaRecognition.releaseStem(url)
      guard let regex = try? NSRegularExpression(pattern: #"^(.+?)[ ._-]+(\d{1,3})$"#),
        let hit = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
        let prefix = Range(hit.range(at: 1), in: stem),
        let numberRange = Range(hit.range(at: 2), in: stem),
        let number = Int(stem[numberRange]), number > 0 else { return nil }
      return (url.deletingLastPathComponent().path + "/" + String(stem[prefix]), number)
    }
    var anchors: [String: [MediaItem]] = [:]
    for item in items where item.localMetadata?.hasSidecar == true {
      if let (key, number) = numbered(item), item.localMetadata?.episode == number, item.localMetadata?.seriesTitle != nil {
        anchors[key, default: []].append(item)
      }
    }
    let organized = items.map { current -> MediaItem in
      guard current.localMetadata?.episode == nil, current.localMetadata?.hasSidecar == false,
        let (key, number) = numbered(current), let options = anchors[key],
        Set(options.compactMap { LibraryCatalog.seriesIdentity($0) }).count == 1,
        let known = options.first, var metadata = known.localMetadata else { return current }
      var item = current
      metadata.episode = number; metadata.episodeEnd = nil; metadata.hasSidecar = false
      metadata.sourceReachable = current.localMetadata?.sourceReachable
      metadata.isExtra = current.localMetadata?.isExtra
      item.title = "第\(number)集"; item.subtitle = "第\(number)集"
      item.poster = metadata.seriesPoster; item.localMetadata = metadata
      return item
    }
    return LibraryScanResult(items: ReleasePackExtras.apply(organized), limited: result.limited, unavailableCount: result.unavailableCount,
      unavailableItems: result.unavailableItems, incremental: result.incremental, reusedCount: result.reusedCount,
      nfoReadCount: result.nfoReadCount, metadataReadFailureIDs: result.metadataReadFailureIDs)
  }
}

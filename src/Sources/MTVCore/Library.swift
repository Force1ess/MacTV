import Foundation

private final class NFODocument: NSObject, XMLParserDelegate {
  var fields: [String: String] = [:]
  private var depth = 0
  private var active: String?
  private var content = ""
  private var rootElement = ""
  var isMovie: Bool { rootElement.lowercased() == "movie" }
  private var movieIDElement: String?
  private var movieIDContent = ""
  private var movieIDs = Set<Int>()
  private var invalidMovieID = false
  var movieTMDBID: Int? { !invalidMovieID && movieIDs.count == 1 ? movieIDs.first : nil }
  private static let names: Set<String> = [
    "title", "showtitle", "plot", "year", "season", "episode",
  ]
  static func read(_ url: URL, within boundary: String? = nil, didRead: () -> Void = {}) -> NFODocument? {
    if let boundary {
      let path = url.resolvingSymlinksInPath().path
      guard path == boundary || path.hasPrefix(boundary + "/") else { return nil }
    }
    guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
      size <= 2_000_000, let data = try? Data(contentsOf: url)
    else { return nil }
    didRead()
    let document = NFODocument()
    let parser = XMLParser(data: data)
    parser.shouldResolveExternalEntities = false
    parser.delegate = document
    guard parser.parse() else { return nil }
    return document
  }
  func parser(
    _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName: String?, attributes: [String: String]
  ) {
    depth += 1
    if depth > 2, movieIDElement != nil { invalidMovieID = true }
    if depth == 1 { rootElement = name }
    if depth == 2, rootElement == "movie", name == "tmdbid" || (name == "uniqueid" && attributes["type"]?.lowercased() == "tmdb") {
      movieIDElement = name; movieIDContent = ""
    }
    if depth == 2, Self.names.contains(name) {
      active = name
      content = ""
    }
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if active != nil { content += string }
    if movieIDElement != nil { movieIDContent += string }
  }
  func parser(
    _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
  ) {
    if depth == 2, movieIDElement == name {
      let text = movieIDContent.trimmingCharacters(in: .whitespacesAndNewlines)
      if text.range(of: #"^[0-9]{1,10}$"#, options: .regularExpression) != nil, let id = Int(text), id > 0 { movieIDs.insert(id) }
      else { invalidMovieID = true }
      movieIDElement = nil
    }
    if depth == 2, active == name {
      let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
      if !value.isEmpty, fields[name] == nil { fields[name] = value }
      active = nil
      content = ""
    }
    depth -= 1
  }
}

public struct LibraryScanResult {
  public let items: [MediaItem]
  public let limited: Bool
  public let unavailableCount: Int
  public let unavailableItems: [MediaItem]
  public var incremental: LibraryIncrementalState? = nil
  public var reusedCount = 0
  public var nfoReadCount = 0
  public var metadataReadFailureIDs = Set<String>()
  public func withSMBIdentity(profile: SMBProfile, mount: URL) throws -> LibraryScanResult {
    let bound = try SMBMediaIdentity.remap(items, profile: profile, mount: mount)
    let boundOffline = try SMBMediaIdentity.remap(unavailableItems, profile: profile, mount: mount)
    let mapping = Dictionary(zip(items + unavailableItems, bound + boundOffline).map { ($0.id, $1.id) }, uniquingKeysWith: { first, _ in first })
    return LibraryScanResult(items: bound,
      limited: limited, unavailableCount: unavailableCount,
      unavailableItems: boundOffline,
      incremental: incremental, reusedCount: reusedCount, nfoReadCount: nfoReadCount,
      metadataReadFailureIDs: Set(metadataReadFailureIDs.compactMap { mapping[$0] }))
  }
  public func catalogItems(preserving previous: [MediaItem] = []) -> [MediaItem] {
    let existing = Dictionary(previous.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    func preserved(_ current: MediaItem, old: MediaItem, failed: Bool) -> MediaItem {
      var item = current
      item.title = old.title; item.subtitle = old.subtitle; item.overview = old.overview
      var metadata = old.localMetadata ?? current.localMetadata
      metadata?.metadataReadFailed = failed ? true : nil
      if failed { metadata?.hasSidecar = true }
      metadata?.sourceReachable = current.localMetadata?.sourceReachable
      if metadata?.seriesIdentity == nil { metadata?.seriesIdentity = current.localMetadata?.seriesIdentity }
      let sameBinding = old.url.flatMap(URL.init(string:))?.standardizedFileURL.path
        == current.url.flatMap(URL.init(string:))?.standardizedFileURL.path
      func cachedArtwork(_ value: String?) -> String? {
        guard let value, URL(string: value)?.scheme == "mtv-artwork" else { return nil }; return value
      }
      func reboundRoot(_ path: String) -> String? {
        guard let oldURL = old.url.flatMap(URL.init(string:)), let newURL = current.url.flatMap(URL.init(string:)),
          oldURL.isFileURL, newURL.isFileURL else { return nil }
        let ancestor = URL(fileURLWithPath: path).standardizedFileURL
        let oldFile = oldURL.standardizedFileURL, newFile = newURL.standardizedFileURL
        guard oldFile.path.hasPrefix(ancestor.path + "/") else { return nil }
        let distance = oldFile.pathComponents.count - ancestor.pathComponents.count
        guard distance > 0, distance < newFile.pathComponents.count else { return nil }
        var result = newFile
        for _ in 0..<distance { result.deleteLastPathComponent() }
        return result.path
      }
      if sameBinding {
        item.poster = current.poster ?? old.poster
        metadata?.seriesPoster = current.localMetadata?.seriesPoster ?? old.localMetadata?.seriesPoster
      } else {
        item.poster = current.poster ?? cachedArtwork(old.poster)
        metadata?.seriesPoster = current.localMetadata?.seriesPoster ?? cachedArtwork(old.localMetadata?.seriesPoster)
        if let oldRoot = metadata?.seriesRoot {
          let rebound = reboundRoot(oldRoot)
          metadata?.seriesRoot = rebound ?? current.localMetadata?.seriesRoot
          if rebound == nil { metadata?.seriesIdentity = current.localMetadata?.seriesIdentity }
        }
      }
      item.localMetadata = metadata
      return item
    }
    let available = items.map { current -> MediaItem in
      guard metadataReadFailureIDs.contains(current.id), let old = existing[current.id] else { return current }
      return preserved(current, old: old, failed: true)
    }
    let offline = unavailableItems.map { item -> MediaItem in
      guard let old = existing[item.id] else { return item }
      var retained = preserved(item, old: old, failed: metadataReadFailureIDs.contains(item.id))
      retained.localMetadata?.sourceReachable = false
      return retained
    }
    return (available + offline).sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
  }
}
public enum LibraryScanner {
  public static let defaultLimit = 10_000
  public static let extensions: Set<String> = ["mkv", "mp4", "m4v", "mov", "avi", "webm", "ts", "m2ts", "mts", "mpg", "mpeg", "wmv", "flv", "rmvb", "asf", "vob", "ogv"]
  public static func scan(root: URL, limit: Int = defaultLimit, allowedResolvedRoot: URL? = nil) throws
    -> [MediaItem]
  {
    return try scanResult(root: root, limit: limit, allowedResolvedRoot: allowedResolvedRoot).items
  }
  public static func scanResult(
    root: URL, limit: Int = defaultLimit, allowedResolvedRoot: URL? = nil,
    previous: LibraryIncrementalState? = nil,
    progress: (@Sendable (Int) -> Void)? = nil)
    throws
    -> LibraryScanResult
  {
    let root = root.standardizedFileURL
    let scanObservedAt = Date()
    let boundaryRoot = root.resolvingSymlinksInPath().path
    let allowed = allowedResolvedRoot?.resolvingSymlinksInPath().path
    let incremental = LibraryIncrementalBuilder(root: root, boundary: allowed, previous: previous)
    var reusedCount = 0, nfoReadCount = 0
    var metadataReadFailureIDs = Set<String>()
    var failedNFOs = Set<String>()
    func permits(_ url: URL) -> Bool {
      guard let allowed else { return true }
      let path = url.resolvingSymlinksInPath().path
      return path == allowed || path.hasPrefix(allowed + "/")
    }
    func artworkExists(_ url: URL) -> Bool {
      guard permits(url) else { return false }
      var directory: ObjCBool = false
      return FileManager.default.fileExists(atPath: url.path, isDirectory: &directory) && !directory.boolValue
    }
    func readNFO(_ url: URL) -> NFODocument? {
      let document = NFODocument.read(url, within: allowed, didRead: { nfoReadCount += 1 })
      if document == nil, permits(url), FileManager.default.fileExists(atPath: url.path) { failedNFOs.insert(url.path) }
      return document
    }
    func dependencies(_ file: URL) -> [String] {
      let folder = file.deletingLastPathComponent()
      var paths = [file.path, file.deletingPathExtension().appendingPathExtension("nfo").path,
        folder.appendingPathComponent("movie.nfo").path]
      if MediaRecognition.numberedEpisodeCandidate(file) != nil { paths.append(folder.path) }
      paths += (LocalArtworkCandidates.posters(for: file) + LocalArtworkCandidates.backdrops(in: folder)
        + LocalArtworkCandidates.backdrops(in: folder.deletingLastPathComponent())).map(\.path)
      var candidate = folder
      for _ in 0..<6 {
        let resolved = candidate.resolvingSymlinksInPath().path
        guard resolved == boundaryRoot || resolved.hasPrefix(boundaryRoot + "/") else { break }
        paths += [candidate.appendingPathComponent("tvshow.nfo").path]
          + (LocalArtworkCandidates.posters(in: candidate) + LocalArtworkCandidates.backdrops(in: candidate)).map(\.path)
        if resolved == boundaryRoot { break }; candidate.deleteLastPathComponent()
      }
      return paths
    }
    guard permits(root) else { throw MTVError.message("目录超出所选共享范围") }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { throw MTVError.message(L("影片目录不存在或未挂载：\(root.path)")) }
    guard limit > 0 else {
      return LibraryScanResult(items: [], limited: true, unavailableCount: 0, unavailableItems: [])
    }
    var items: [MediaItem] = []
    var unavailableItems: [MediaItem] = []
    var traversalError: Error?
    var limited = false
    var unavailableCount = 0
    progress?(0)
    guard
      let enumerator = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles],
        errorHandler: { _, error in
          traversalError = error
          return false
        })
    else {
      throw MTVError.message("无法读取影片目录")
    }
    struct ShowContext {
      let root: URL
      let document: NFODocument
    }
    var shows: [String: ShowContext] = [:]
    var noShow = Set<String>()
    var showSidecars = Set<String>()
    var numberedContexts: [String: [String: RecognizedFilename]] = [:]
    func showContext(_ folder: URL) -> ShowContext? {
      if let cached = shows[folder.path] { return cached }
      if noShow.contains(folder.path) { return nil }
      var candidate = folder
      for _ in 0..<6 {
        let boundary = candidate.resolvingSymlinksInPath().path
        guard boundary == boundaryRoot || boundary.hasPrefix(boundaryRoot + "/") else {
          break
        }
        let sidecar = candidate.appendingPathComponent("tvshow.nfo")
        if permits(sidecar), FileManager.default.fileExists(atPath: sidecar.path) {
          showSidecars.insert(folder.path)
        }
        if let document = readNFO(candidate.appendingPathComponent("tvshow.nfo"))
        {
          let result = ShowContext(root: candidate, document: document)
          shows[folder.path] = result
          return result
        }
        if boundary == boundaryRoot { break }
        candidate.deleteLastPathComponent()
      }
      noShow.insert(folder.path)
      return nil
    }
    func number(_ text: String?, range: ClosedRange<Int>) -> Int? {
      guard let text, let value = Int(text), range.contains(value) else { return nil }
      return value
    }
    for case let enumeratedFile as URL in enumerator {
      try Task.checkCancellation()
      let entry = enumeratedFile.standardizedFileURL
      // FileManager may return canonical paths for an aliased source (e.g. /var).
      // Keep identities under the user's selected root, without resolving on cache reads.
      let file: URL
      if root.path != boundaryRoot, entry.path.hasPrefix(boundaryRoot + "/") {
        file = root.appendingPathComponent(String(entry.path.dropFirst(boundaryRoot.count + 1)))
      } else {
        file = entry
      }
      guard extensions.contains(file.pathExtension.lowercased()) else { continue }
      let resolved = file.resolvingSymlinksInPath()
      guard permits(resolved) else { continue }
      var directory: ObjCBool = false
      let reachable = FileManager.default.fileExists(atPath: resolved.path, isDirectory: &directory)
      guard !directory.boolValue else { continue }
      if items.count + unavailableItems.count >= limit {
        limited = true
        break
      }
      let dependencyPaths = dependencies(file)
      let observed = incremental.observe(dependencyPaths)
      let dates = reachable ? (try? file.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])) : nil
      let addedAt = dates?.addedToDirectoryDate ?? dates?.creationDate
        ?? previous?.items[file.path]?.addedAt ?? (reachable ? scanObservedAt : nil)
      if reachable, !incremental.hasNFOReadErrors(observed), var cached = incremental.reused(file: file, dependencies: observed) {
        cached.addedAt = addedAt
        cached.localMetadata?.sourceReachable = true
        items.append(cached); reusedCount += 1
        incremental.record(file: file, dependencies: observed, readable: true)
        let count = items.count + unavailableItems.count
        if count.isMultiple(of: 100) { progress?(count) }
        continue
      }
      let folder = file.deletingLastPathComponent()
      let filenameHint = MediaRecognition.filename(file)
      var hint = filenameHint
      if hint.episode == nil {
        if numberedContexts[folder.path] == nil {
          numberedContexts[folder.path] = MediaRecognition.numberedEpisodes(in: folder,
            filenames: incremental.directoryNames(folder) ?? [])
        }
        hint = numberedContexts[folder.path]?[file.lastPathComponent] ?? filenameHint
      }
      let document =
        readNFO(file.deletingPathExtension().appendingPathExtension("nfo"))
        ?? (hint.episode == nil
          ? readNFO(folder.appendingPathComponent("movie.nfo")) : nil)
      if document?.isMovie == true { hint = filenameHint }
      let fields = document?.fields ?? [:]
      let season = number(fields["season"], range: 0...99) ?? hint.season
      let episode = number(fields["episode"], range: 1...9999) ?? hint.episode
      let show = episode == nil ? nil : showContext(folder)
      var metadata = LocalMediaMetadata(
        year: number(fields["year"], range: 1800...2199) ?? hint.year)
      metadata.sourceReachable = reachable
      metadata.isExtra = MediaRecognition.isExtra(file)
      if episode == nil { metadata.movieTMDBID = document?.movieTMDBID }
      let sidecar = file.deletingPathExtension().appendingPathExtension("nfo")
      let movieSidecar = folder.appendingPathComponent("movie.nfo")
      metadata.hasSidecar =
        document != nil || show != nil || showSidecars.contains(folder.path)
        || (permits(sidecar) && FileManager.default.fileExists(atPath: sidecar.path))
        || (hint.episode == nil && permits(movieSidecar)
          && FileManager.default.fileExists(atPath: movieSidecar.path))
      if let season, let episode {
        let seriesRoot =
          show?.root
          ?? (MediaRecognition.isSeasonDirectory(folder.lastPathComponent)
            ? folder.deletingLastPathComponent() : folder)
        let inferredTitle = hint.seriesTitle.flatMap { $0.isEmpty ? nil : $0 }
        metadata.seriesTitle =
          fields["showtitle"] ?? show?.document.fields["title"]
          ?? inferredTitle ?? MediaRecognition.cleanTitle(seriesRoot.lastPathComponent)
        metadata.seriesRoot = seriesRoot.path
        metadata.season = season
        metadata.episode = episode
        metadata.episodeEnd = hint.episodeEnd
        metadata.seriesOverview = show?.document.fields["plot"]
        if let seriesPoster = LocalArtworkCandidates.posters(in: seriesRoot).first(where: artworkExists) {
          metadata.seriesPoster = seriesPoster.absoluteString
        }
      }
      let posters = LocalArtworkCandidates.posters(for: file, seriesRoot: show?.root)
      let poster = posters.first(where: artworkExists)
      let title = fields["title"] ?? hint.title
      let metadataFailed = dependencyPaths.contains(where: { failedNFOs.contains($0) }) || incremental.hasNFOReadErrors(observed)
      if metadataFailed { metadata.metadataReadFailed = true; metadata.hasSidecar = true; metadataReadFailureIDs.insert(file.path) }
      let subtitle: String
      if let season = metadata.season, let episode = metadata.episode {
        subtitle = "第 \(season) 季 · 第 \(episode)\(metadata.episodeEnd.map { "-\($0)" } ?? "") 集"
      } else {
        subtitle = metadata.year.map(String.init) ?? "本地影片"
      }
      let item = MediaItem(
        id: file.path, title: title, subtitle: subtitle,
        overview: fields["plot"] ?? "",
        poster: poster?.absoluteString, url: file.absoluteString, localMetadata: metadata, addedAt: addedAt)
      if reachable {
        items.append(item)
        incremental.record(file: file, dependencies: observed, readable: !metadataFailed)
      } else {
        unavailableCount += 1
        unavailableItems.append(item)
      }
      let discovered = items.count + unavailableItems.count
      if discovered.isMultiple(of: 100) { progress?(discovered) }
    }
    if let traversalError { throw traversalError }
    let discovered = items.count + unavailableItems.count
    if !discovered.isMultiple(of: 100) { progress?(discovered) }
    return LibraryScanResult(
      items: items.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending },
      limited: limited, unavailableCount: unavailableCount, unavailableItems: unavailableItems,
      incremental: try incremental.finish(items: items), reusedCount: reusedCount, nfoReadCount: nfoReadCount,
      metadataReadFailureIDs: metadataReadFailureIDs)
  }
}

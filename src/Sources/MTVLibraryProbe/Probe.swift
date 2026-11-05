import Foundation
import MTVCore

@main enum Probe {
  static func main() async {
    do { try await run() }
    catch {
      let failure: [String: Any] = ["schema": 1, "error": ["code": "library-inspection-failed", "message": error.localizedDescription]]
      if let data = try? JSONSerialization.data(withJSONObject: failure, options: [.sortedKeys]) {
        FileHandle.standardError.write(data + Data([10]))
      }
      exit(1)
    }
  }
  static func run() async throws {
    let arguments = Array(CommandLine.arguments.dropFirst())
    if arguments.first == "--inspect-selected" || arguments.first == "--inspect" {
      let selected = arguments.first == "--inspect-selected"
      let store = LibraryIndexStore()
      let root: URL
      if selected {
        guard let source = try await LibrarySourceStore().load(), let path = source.path else {
          throw MTVError.message("当前没有已选择的本地/挂载磁盘来源；此接口不会自动连接NAS")
        }
        root = URL(fileURLWithPath: path)
      } else {
        guard arguments.count >= 2, !arguments[1].hasPrefix("--") else { throw MTVError.message("用法：--inspect /影片目录 [--check] [--require-posters]") }
        root = URL(fileURLWithPath: arguments[1]).standardizedFileURL
      }
      let files: [MediaItem]
      if selected {
        guard let snapshot = try await store.load(root: root) else { throw MTVError.message("当前来源还没有缓存索引") }
        files = snapshot.items
      } else {
        let scan = try LibraryScanner.scanResult(root: root)
        guard !scan.limited else { throw MTVError.message("扫描超过上限，不输出不完整清单") }
        let registry = SavedLibrarySourcesStore(file: LibrarySourceStore.normalFile.deletingPathExtension().appendingPathExtension("saved.json"))
        var companions: [MediaItem] = []
        for source in try await registry.load() {
          guard companions.count < 10_000, let path = source.path, path != root.path else { continue }
          if let snapshot = try await store.load(root: URL(fileURLWithPath: path)) { companions += snapshot.items.prefix(10_000 - companions.count) }
        }
        files = LibraryLinkedMetadata.apply(scan, companions: companions, root: root).catalogItems()
      }
      let report = LibraryInventoryReport(root: root, basis: selected ? "cached-index" : "cli-read-only-scan", files: files, matches: try MetadataStore().load())
      let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      print(String(decoding: try encoder.encode(report), as: UTF8.self))
      if arguments.contains("--check"), !report.checkPassed { exit(2) }
      if arguments.contains("--require-posters"), report.summary.missingPosters > 0 { exit(3) }
      return
    }
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--select-source" {
      let root = URL(fileURLWithPath: CommandLine.arguments[2]).standardizedFileURL
      // Validate accessibility and completeness before changing only MTV's source.
      let scan = try LibraryScanner.scanResult(root: root)
      guard !scan.limited else { throw MTVError.message("来源超过扫描上限，未切换") }
      let store = LibrarySourceStore()
      if let prior = try await store.load() {
        let backup = LibrarySourceStore.normalFile.deletingLastPathComponent().appendingPathComponent("source-before-switch-" + UUID().uuidString + ".json")
        try await LibrarySourceStore(file: backup).save(prior)
      }
      let selection = LibrarySourceSelection(path: root.path)
      try await store.save(selection)
      let saved = SavedLibrarySourcesStore(file: LibrarySourceStore.normalFile.deletingLastPathComponent().appendingPathComponent("source.saved.json"))
      _ = try await saved.remember(selection, title: root.lastPathComponent)
      print("Selected source: \(root.path); accessible videos: \(scan.items.count)")
      return
    }
    if CommandLine.arguments.count == 4,
      ["--index-save", "--index-load"].contains(CommandLine.arguments[1])
    {
      let mode = CommandLine.arguments[1]
      let root = URL(fileURLWithPath: CommandLine.arguments[2])
      let store = LibraryIndexStore(file: URL(fileURLWithPath: CommandLine.arguments[3]))
      if mode == "--index-save" {
        let scan = try LibraryScanner.scanResult(root: root)
        guard !scan.limited else { throw MTVError.message("不保存被截断的索引") }
        let previous = try await store.load(root: root)?.items ?? []
        try await store.save(items: scan.catalogItems(preserving: previous), root: root)
      }
      guard let snapshot = try await store.load(root: root) else {
        throw MTVError.message("没有对应来源的索引")
      }
      let result: [String: Any] = [
        "pid": ProcessInfo.processInfo.processIdentifier,
        "mode": mode, "items": snapshot.items.count, "titles": snapshot.items.map(\.title),
        "sourcePath": snapshot.sourcePath,
        "withPoster": snapshot.items.filter { $0.poster != nil || $0.localMetadata?.seriesPoster != nil }.count,
        "sidecarDescriptions": snapshot.items.filter { $0.localMetadata?.hasSidecar == true }.count,
        "physicalSourceURLs": snapshot.items.filter { $0.url.flatMap(URL.init(string:))?.path.hasPrefix(root.path + "/") == true }.count,
        "mediaRead": mode == "--index-save", "networkRequested": false,
      ]
      print(
        String(
          decoding: try JSONSerialization.data(
            withJSONObject: result, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
      return
    }
    guard CommandLine.arguments.count == 2 else {
      throw MTVError.message("传入只读扫描目录")
    }
    let files = try LibraryScanner.scan(root: URL(fileURLWithPath: CommandLine.arguments[1]))
    let catalog = LibraryCatalog.build(files)
    let series = catalog.root.filter { $0.kind == .series }.map { item -> [String: Any] in
      let seasons = catalog.children[item.id] ?? []
      return [
        "title": item.title, "seasons": seasons.map(\.title),
        "videos": seasons.reduce(0) { $0 + (catalog.children[$1.id]?.count ?? 0) },
      ]
    }
    let result: [String: Any] = [
      "files": files.count, "rootCards": catalog.root.count,
      "movies": catalog.root.filter { !$0.isLibraryCollection }.count,
      "episodeFiles": files.filter { $0.localMetadata?.episode != nil }.count,
      "series": series, "mediaModified": false, "externalMetadataRequested": false,
    ]
    let data = try JSONSerialization.data(
      withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    print(String(decoding: data, as: UTF8.self))
  }
}

import AppKit
import Foundation
import MTVCore

@main enum Probe {
  static func main() async {
    do { exit(try await run()) }
    catch {
      let result: [String: Any] = ["schema": 1, "error": ["code": "metadata-probe-failed", "message": error.localizedDescription]]
      if let data = try? JSONSerialization.data(withJSONObject: result, options: [.sortedKeys]) {
        FileHandle.standardError.write(data + Data([10]))
      }
      exit(1)
    }
  }
  static func output(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data + Data([10]))
  }
  static func object<T: Encodable>(_ value: T) throws -> Any {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
  }
  static func appRunning() -> Bool {
    !NSRunningApplication.runningApplications(withBundleIdentifier: "local.mtv.preview").isEmpty
  }
  static func run() async throws -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--configure-tmdb-from-stdin"] {
      guard !appRunning() else { throw MTVError.message("请先退出MTV再配置，完成后重新打开。") }
      guard isatty(STDIN_FILENO) == 0 else { throw MTVError.message("令牌只能通过标准输入传入，不能作为命令参数。") }
      var data = Data()
      while data.count <= 4096 {
        guard let byte = try FileHandle.standardInput.read(upToCount: 1), !byte.isEmpty else { break }
        if byte == Data([10]) { break }
        data.append(byte)
      }
      guard data.count <= 4096, let input = String(data: data, encoding: .utf8) else { throw MTVError.message("访问令牌格式无效") }
      let token = input.trimmingCharacters(in: .whitespacesAndNewlines)
      // Validate against TMDB before persisting. The token is an HTTP header,
      // never part of a URL, output, or command argument.
      _ = try await MetadataClient().search(query: "Interstellar", kind: .movie, provider: .tmdb, token: token)
      guard !appRunning() else { throw MTVError.message("MTV已重新启动，取消配置，请退出后重试。") }
      guard let defaults = UserDefaults(suiteName: "local.mtv.preview") else { throw MTVError.message("无法打开MTV偏好设置") }
      let store = MetadataTokenStore(defaults: defaults)
      try store.save(token)
      guard defaults.synchronize(), try store.load() == token else { throw MTVError.message("令牌保存验证失败") }
      try output(["schema": 1, "provider": "tmdb", "authenticationVerified": true, "saved": true, "keychainWritten": false])
      return 0
    }
    if args.first == "--search-tmdb" {
      guard args.count == 3, let kind = MetadataKind(rawValue: args[1]),
        let defaults = UserDefaults(suiteName: "local.mtv.preview"),
        let token = try MetadataTokenStore(defaults: defaults).load()
      else { throw MTVError.message("用法：--search-tmdb movie|series 片名，需要已保存的TMDB令牌") }
      let candidates = try await MetadataClient().search(query: args[2], kind: kind, provider: .tmdb, token: token)
      try output(["schema": 1, "provider": "tmdb", "credentialsRead": true,
        "libraryModified": false, "results": try object(candidates)])
      return 0
    }
    if args.first != "--audit-selected" {
      guard args.count == 1, !args[0].hasPrefix("--") else { throw MTVError.message("用法：公开剧集名，或 --audit-selected [--apply-automatic] [--require-complete]") }
      let values = try await MetadataClient().search(query: args[0], kind: .series, provider: .tvmaze, token: nil)
      try output(["provider": "tvmaze", "count": values.count, "results": values.map {
        ["id": $0.externalID, "title": $0.title, "aliases": $0.officialAliases ?? [], "hasPoster": $0.poster != nil, "attribution": $0.attribution.absoluteString] as [String: Any]
      }, "credentialsRead": false, "libraryModified": false])
      return values.isEmpty ? 1 : 0
    }
    guard Set(args).isSubset(of: ["--audit-selected", "--apply-automatic", "--require-complete", "--use-saved-tmdb"]), Set(args).count == args.count else {
      throw MTVError.message("识别审计参数无效")
    }
    let apply = args.contains("--apply-automatic")
    if apply && appRunning() { throw MTVError.message("请先退出MTV再应用自动匹配，避免覆盖应用正在保存的资料。只读审计不需要退出。") }
    guard let source = try await LibrarySourceStore().load(), let path = source.path else { throw MTVError.message("当前没有本地来源；此工具不会自动连接NAS。") }
    let root = URL(fileURLWithPath: path)
    guard let snapshot = try await LibraryIndexStore().load(root: root) else { throw MTVError.message("当前来源没有缓存索引。") }
    let store = MetadataStore(), records = try store.load()
    let before = LibraryInventoryReport(root: root, basis: "cached-index", files: snapshot.items, matches: records)
    let targets = AutomaticMetadata.targets(files: snapshot.items, matches: records)
    guard targets.count <= 64 else { throw MTVError.message("当前待识别内容超过64项，请分批整理后再审计。") }
    let client = MetadataClient()
    let useSavedToken = args.contains("--use-saved-tmdb")
    let token = try useSavedToken ? MetadataTokenStore(defaults: UserDefaults(suiteName: "local.mtv.preview")!).load() : nil
    var rows: [[String: Any]] = [], ready: [(AutomaticMetadataTarget, MetadataCandidate)] = []
    for target in targets {
      var row: [String: Any] = ["targetID": target.id, "title": target.item.title, "kind": target.kind.rawValue, "provider": target.provider.rawValue]
      if target.kind == .movie && token == nil {
        // Credential access is explicit; never substitute another service.
        row["status"] = "movie-provider-credential-required"
      } else {
        do {
          let candidates = try await client.search(query: target.item.title, kind: target.kind, provider: target.provider, token: target.provider == .tmdb ? token : nil)
          row["candidateCount"] = candidates.count
          if let selected = AutomaticMetadata.uniqueMatch(target: target, candidates: candidates) {
            row["candidateTitle"] = selected.title; row["attribution"] = selected.attribution.absoluteString
            row["status"] = selected.poster == nil ? "unique-match-without-artwork" : "ready"
            if selected.poster != nil { ready.append((target, selected)) }
          } else { row["status"] = "no-unique-exact-match" }
        } catch { row["status"] = "lookup-failed"; row["error"] = error.localizedDescription }
        try await Task.sleep(for: .milliseconds(600))
      }
      rows.append(row)
    }
    var added = 0
    var backup: URL?
    if apply && !ready.isEmpty {
      guard !appRunning() else { throw MTVError.message("MTV已重新启动，取消写入；请退出后重试。") }
      backup = try store.backupForMaintenance()
      for (target, selected) in ready {
        guard !appRunning() else { throw MTVError.message("MTV已启动，停止继续写入；已完成的匹配保留。") }
        if try store.insertAutomatic(targetID: target.id, candidate: selected) { added += 1 }
      }
    }
    let after = LibraryInventoryReport(root: root, basis: "cached-index", files: snapshot.items, matches: try store.load())
    var result: [String: Any] = ["schema": 1, "basis": "cached-index", "sourcePath": path,
      "summaryBefore": try object(before.summary), "summaryAfter": try object(after.summary), "rows": rows,
      "readyMatches": ready.count, "addedMatches": added, "libraryModified": added > 0,
      "credentialsRead": useSavedToken, "mediaOrNFOModified": false, "volumeReadVerified": false,
      "recognitionComplete": after.summary.missingPosters == 0 && after.checkPassed]
    if let backup { result["backupPath"] = backup.path }
    try output(result)
    return args.contains("--require-complete") && (after.summary.missingPosters > 0 || !after.checkPassed) ? 3 : 0
  }
}

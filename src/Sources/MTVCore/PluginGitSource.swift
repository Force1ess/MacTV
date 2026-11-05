import Darwin
import Foundation

public struct PluginGitFailure: LocalizedError, Sendable {
  public let kind: String
  public var errorDescription: String? {
    switch kind {
    case "host-key": return L("Git could not verify the SSH host key. Verify this server with SSH before refreshing the source.")
    case "ssh-auth": return L("SSH could not authenticate. Check the SSH key or agent configured for this Mac.")
    case "credentials": return L("Git needs repository access. Configure Git credentials or use an SSH repository URL.")
    case "timeout": return L("The Git source operation timed out.")
    case "limit": return L("This Git source exceeds the supported size limit.")
    case "unavailable": return L("Git is unavailable on this Mac. Install Git or Command Line Tools to refresh Git sources.")
    default: return L("Git could not read this repository or branch. Check its address and access permissions.")
    }
  }
}

private enum PluginGitTools {
  // Avoid executing Apple's /usr/bin/git installer stub on a machine without
  // developer tools. Existing Homebrew Git also works without opening a prompt.
  static let executable: Result<URL,Error> = Result {
    var candidates=["/opt/homebrew/bin/git","/usr/local/bin/git","/Library/Developer/CommandLineTools/usr/bin/git"]
    if let developer=ProcessInfo.processInfo.environment["DEVELOPER_DIR"] { candidates.insert(developer+"/usr/bin/git",at:0) }
    let selector=Process(), output=Pipe()
    selector.executableURL=URL(fileURLWithPath:"/usr/bin/xcode-select"); selector.arguments=["-p"]
    selector.standardInput=FileHandle.nullDevice; selector.standardOutput=output; selector.standardError=FileHandle.nullDevice
    if (try? selector.run()) != nil {
      let data=try output.fileHandleForReading.readToEnd() ?? Data(); selector.waitUntilExit()
      if selector.terminationStatus==0 { candidates.insert(String(decoding:data,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)+"/usr/bin/git",at:0) }
    }
    guard let path=candidates.first(where:{FileManager.default.isExecutableFile(atPath:$0)}) else { throw PluginGitFailure(kind:"unavailable") }
    return URL(fileURLWithPath:path)
  }
}

private final class GitErrorCapture: @unchecked Sendable {
  private let lock=NSLock(); private var bytes=Data()
  func append(_ value: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(value.prefix(max(0,8192-bytes.count))) }
  var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding:bytes,as:UTF8.self) }
}

private final class GitSourceOperation: @unchecked Sendable {
  private let lock=NSLock(); private var process: Process?; private var cancelled=false; private var timedOut=false
  func cancel(timeout: Bool = false) {
    lock.lock(); cancelled=true; timedOut = timedOut || timeout; let child=process; lock.unlock()
    if let child, child.isRunning {
      let family=ApplicationProcessFamily.descendants(of:[child.processIdentifier])
      for pid in family where pid != child.processIdentifier { kill(pid,SIGKILL) }
      if child.isRunning { kill(child.processIdentifier,SIGKILL) }
    }
  }
  func run(_ arguments: [String], maximum: Int, localFixture: Bool = false) throws -> Data {
    let child=Process(), output=Pipe(), errors=Pipe(), capture=GitErrorCapture(), group=DispatchGroup()
    child.executableURL=try PluginGitTools.executable.get()
    child.arguments=["-c","core.hooksPath=/dev/null","-c","core.fsmonitor=false","-c","gc.auto=0","-c","maintenance.auto=false","-c","protocol.ext.allow=never","-c","protocol.file.allow="+(localFixture ? "always":"never")]+arguments
    var environment=ProcessInfo.processInfo.environment
    environment["GIT_TERMINAL_PROMPT"]="0"
    // Preserve GIT_SSH/GIT_SSH_COMMAND, core.sshCommand, SSH config and agent.
    // No TTY is attached; the owned process family has a bounded deadline.
    environment["GIT_LFS_SKIP_SMUDGE"]="1"
    child.environment=environment
    child.standardInput=FileHandle.nullDevice; child.standardOutput=output; child.standardError=errors
    lock.lock()
    guard !cancelled else { let timeout=timedOut; lock.unlock(); if timeout { throw PluginGitFailure(kind:"timeout") }; throw CancellationError() }
    do { try child.run(); process=child; lock.unlock() } catch { lock.unlock(); throw error }
    group.enter()
    DispatchQueue.global().async {
      defer { group.leave() }
      while let part=try? errors.fileHandleForReading.read(upToCount:4096), !part.isEmpty { capture.append(part) }
    }
    let deadline=DispatchWorkItem { self.cancel(timeout:true) }
    DispatchQueue.global().asyncAfter(deadline:.now()+45,execute:deadline)
    defer {
      deadline.cancel()
      if child.isRunning { cancel() }
      child.waitUntilExit(); group.wait()
      try? output.fileHandleForReading.close(); try? errors.fileHandleForReading.close()
    }
    var data=Data()
    while let part=try output.fileHandleForReading.read(upToCount:min(65_536,maximum+1-data.count)), !part.isEmpty {
      data.append(part)
      if data.count>maximum { cancel(); throw PluginGitFailure(kind:"limit") }
    }
    child.waitUntilExit(); group.wait()
    lock.lock(); let stopped=cancelled, timeout=timedOut; lock.unlock()
    if timeout { throw PluginGitFailure(kind:"timeout") }; if stopped { throw CancellationError() }
    guard child.terminationStatus==0 else {
      let text=capture.text
      if text.contains("Host key verification failed") { throw PluginGitFailure(kind:"host-key") }
      if text.contains("Permission denied (publickey)") { throw PluginGitFailure(kind:"ssh-auth") }
      if text.contains("terminal prompts disabled") || text.contains("could not read Username") { throw PluginGitFailure(kind:"credentials") }
      throw PluginGitFailure(kind:"repository")
    }
    return data
  }
}

public struct PluginGitSnapshot: Sendable {
  public let revision: String
  public let catalog: PluginSourceCatalog
}

public actor PluginSourceClient {
  public static let shared=PluginSourceClient()
  private let root: URL
  private let testRoot: URL?
  private let gate=AsyncWorkGate(limit:1)
  public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/MacTV/PluginRepositories")) { self.root=root; testRoot=nil }
  init(root: URL, testRoot: URL) { self.root=root; self.testRoot=testRoot }
  private func path(_ source: PluginSource) -> URL { root.appendingPathComponent(source.id+".git") }
  public func catalog(source: PluginSource) async throws -> PluginGitSnapshot {
    try source.validate(localRoot:testRoot)
    guard source.enabled else { throw MTVError.message(L("This plugin source is disabled.")) }
    return try await gate.run { try await self.readCatalog(source) }
  }
  private func readCatalog(_ source: PluginSource) async throws -> PluginGitSnapshot {
    let operation=GitSourceOperation(), repository=path(source), fixture=URL(string:source.repository)?.isFileURL == true
    return try await withTaskCancellationHandler(operation: {
      try await Task.detached(priority:.utility) { [root] in
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        if !FileManager.default.fileExists(atPath:repository.path) {
          let temporary=root.appendingPathComponent("clone-"+UUID().uuidString+".git")
          defer { try? FileManager.default.removeItem(at:temporary) }
          _ = try operation.run(["clone","--quiet","--bare","--depth=1","--single-branch","--no-tags","--branch",source.reference,"--",source.repository,temporary.path],maximum:4096,localFixture:fixture)
          try FileManager.default.moveItem(at:temporary,to:repository)
        }
        let prefix=["--git-dir",repository.path]
        let remote=String(decoding:try operation.run(prefix+["config","--get","remote.origin.url"],maximum:4096,localFixture:fixture),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        guard remote==source.repository else { throw PluginGitFailure(kind:"repository") }
        _ = try operation.run(prefix+["fetch","--quiet","--depth=1","--no-tags","origin",source.reference],maximum:4096,localFixture:fixture)
        let revision=String(decoding:try operation.run(prefix+["rev-parse","--verify","FETCH_HEAD^{commit}"],maximum:128,localFixture:fixture),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
        guard revision.range(of:#"^[a-f0-9]{40,64}$"#,options:.regularExpression) != nil else { throw PluginGitFailure(kind:"repository") }
        let data=try Self.blob("catalog.json",revision:revision,repository:repository,operation:operation,maximum:524_288,fixture:fixture)
        return try PluginGitSnapshot(revision:revision,catalog:PluginSourceCatalog(data:data!))
      }.value
    },onCancel:{ operation.cancel() })
  }
  private static func blob(_ file: String, revision: String, repository: URL, operation: GitSourceOperation, maximum: Int, fixture: Bool, optional: Bool = false) throws -> Data? {
    let prefix=["--git-dir",repository.path]
    let listing=String(decoding:try operation.run(prefix+["ls-tree",revision,"--",file],maximum:4096,localFixture:fixture),as:UTF8.self)
    if listing.isEmpty && optional { return nil }
    guard listing.hasPrefix("100644 blob ") || listing.hasPrefix("100755 blob ") else { throw MTVError.message(L("Plugin packages cannot contain symbolic links or submodules.")) }
    let object=revision+":"+file
    let size=String(decoding:try operation.run(prefix+["cat-file","-s",object],maximum:64,localFixture:fixture),as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
    guard let count=Int(size), count>0, count<=maximum else { throw PluginGitFailure(kind:"limit") }
    return try operation.run(prefix+["cat-file","blob",object],maximum:maximum,localFixture:fixture)
  }
  public func stage(_ entry: PluginSourceEntry, source: PluginSource, revision: String, into directory: URL) async throws -> PluginManifest {
    try source.validate(localRoot:testRoot); try entry.validate()
    guard entry.isCompatible else { throw MTVError.message(L("Requires a newer MacTV")) }
    guard source.enabled, revision.range(of:#"^[a-f0-9]{40,64}$"#,options:.regularExpression) != nil else { throw PluginGitFailure(kind:"repository") }
    return try await gate.run { try await self.stageUnlocked(entry,source:source,revision:revision,into:directory) }
  }
  private func stageUnlocked(_ entry: PluginSourceEntry, source: PluginSource, revision: String, into directory: URL) async throws -> PluginManifest {
    let operation=GitSourceOperation(), repository=path(source), fixture=URL(string:source.repository)?.isFileURL == true
    return try await withTaskCancellationHandler(operation: {
      try await Task.detached(priority:.utility) {
        guard !FileManager.default.fileExists(atPath:directory.path) else { throw PluginGitFailure(kind:"repository") }
        let data=try Self.blob("catalog.json",revision:revision,repository:repository,operation:operation,maximum:524_288,fixture:fixture)
        guard try PluginSourceCatalog(data:data!).plugins.contains(entry) else { throw MTVError.message(L("This plugin is not in the selected catalog revision.")) }
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        var succeeded=false
        defer { if !succeeded { try? FileManager.default.removeItem(at:directory) } }
        let limits=["manifest.json":16_384,"plugin.js":1_000_000,"README.md":65_536,"LICENSE":65_536,"LICENSE.txt":65_536,"NOTICE":65_536]
        for name in limits.keys.sorted() {
          let file=entry.directory.isEmpty ? name:entry.directory+"/"+name
          if let bytes=try Self.blob(file,revision:revision,repository:repository,operation:operation,maximum:limits[name]!,fixture:fixture,optional:!["manifest.json","plugin.js"].contains(name)) {
            try bytes.write(to:directory.appendingPathComponent(name),options:.withoutOverwriting)
          }
        }
        let manifest=try JSONDecoder().decode(PluginManifest.self,from:PluginPackageFiles.read("manifest.json",at:directory,maximum:16_384))
        try manifest.validate()
        guard manifest.id==entry.id, manifest.version==entry.version, manifest.apiVersion==entry.apiVersion else { throw MTVError.message(L("The catalog and plugin manifest do not match.")) }
        succeeded=true; return manifest
      }.value
    },onCancel:{ operation.cancel() })
  }
}

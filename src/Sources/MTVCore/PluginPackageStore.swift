import AppKit
import Darwin
import Foundation

public struct PluginInstallationOrigin: Codable, Equatable, Sendable {
  public let kind: String
  public let sourceID: String
  public let repository: String
  public let reference: String
  public let revision: String?
  public init(kind: String, source: PluginSource, revision: String? = nil) {
    self.kind=kind; sourceID=source.id; repository=source.repository; reference=source.reference; self.revision=revision
  }
  public func validate() throws {
    try PluginSource(id:sourceID,name:sourceID,repository:repository,reference:reference).validate()
    guard ["git","bundled"].contains(kind), kind != "git" || revision?.range(of:#"^[a-f0-9]{40,64}$"#,options:.regularExpression) != nil else { throw MTVError.message("Invalid plugin installation origin") }
  }
}

public struct PluginInstallReview: Identifiable {
  public let id: UUID
  public let manifest: PluginManifest
  public let source: URL
  public let replacingVersion: String?
  public let noticeNames: [String]
  public let origin: PluginInstallationOrigin?
}
public struct InstalledPluginPackage: Codable, Identifiable {
  public var id: String { manifest.id }
  public let receipt: UUID
  public let manifest: PluginManifest
  public var enabled: Bool
  public let installedAt: Date
  public var origin: PluginInstallationOrigin? = nil
}
public enum PluginPackageFiles {
  public static func read(_ name: String, at directory: URL, maximum: Int, allowEmpty: Bool = false) throws -> Data {
    guard ["manifest.json", "plugin.js", "installed.json", "LICENSE", "LICENSE.txt", "NOTICE", "README.md"].contains(name) else { throw MTVError.message("插件文件名称无效") }
    let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
    let fd = open(canonical.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw MTVError.message("插件目录不可读取") }; defer { close(fd) }
    let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard file >= 0 else { throw MTVError.message(L("插件文件缺失或不允许使用符号链接：") + name) }
    let handle = FileHandle(fileDescriptor: file, closeOnDealloc: true); defer { try? handle.close() }
    var before = stat()
    guard fstat(file, &before) == 0, before.st_mode & S_IFMT == S_IFREG, (before.st_size > 0 || allowEmpty), before.st_size <= maximum else { throw MTVError.message(L("插件文件不是普通文件或超过大小限制：") + name) }
    let data = try handle.read(upToCount: maximum + 1) ?? Data()
    var after = stat()
    guard data.count == before.st_size, fstat(file, &after) == 0, LibraryNodeIdentity(before) == LibraryNodeIdentity(after) else { throw MTVError.message("插件文件在读取期间发生变化") }
    return data
  }
}
private struct PluginInstallDocument: Codable {
  let schema: Int
  var packages: [InstalledPluginPackage]
  var seededExamples: [String]? = nil
}

/// Private two-file JS packages. No package code runs during review or installation.
public actor PluginPackageStore {
  public let root: URL
  private struct Pending { let review: PluginInstallReview; let manifest: Data; let script: Data; let notices: [String: Data] }
  private var pending: [UUID: Pending] = [:]
  public init(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/PluginPackages")) { self.root = root.standardizedFileURL }
  private var index: URL { root.appendingPathComponent("installed.json") }
  private func folder(_ receipt: UUID) -> URL { root.appendingPathComponent("packages/" + receipt.uuidString.lowercased()) }
  private func stage(_ receipt: UUID) -> URL { root.appendingPathComponent("staging/" + receipt.uuidString.lowercased()) }
  public static func approvalBytes(_ manifest: PluginManifest) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(manifest)
  }
  private func validateExternal(_ manifest: PluginManifest) throws {
    try manifest.validate()
    guard manifest.id != "mtv", !manifest.id.hasPrefix("mtv."), manifest.id.utf8.count <= 128,
      manifest.name.count <= 80, manifest.name.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }),
      manifest.version.range(of: #"^[A-Za-z0-9][A-Za-z0-9._+-]{0,63}$"#, options: .regularExpression) != nil
    else { throw MTVError.message("外部插件标识/名称/版本无效，mtv 命名空间保留给内置模块") }
  }
  private func read(_ name: String, at directory: URL, maximum: Int) throws -> Data {
    try PluginPackageFiles.read(name, at: directory, maximum: maximum)
  }
  private func readPackage(_ directory: URL) throws -> (PluginManifest, Data, Data) {
    let bytes = try read("manifest.json", at: directory, maximum: 16_384)
    let manifest = try JSONDecoder().decode(PluginManifest.self, from: bytes)
    try validateExternal(manifest)
    let script = try read("plugin.js", at: directory, maximum: 1_000_000)
    guard String(data: script, encoding: .utf8) != nil else { throw MTVError.message("插件脚本必须是 UTF-8 文本") }
    let approval = try Self.approvalBytes(manifest)
    guard approval.count <= 16_384 else { throw MTVError.message("插件权限清单超过大小限制") }
    return (manifest, approval, script)
  }
  private func writePackage(_ manifest: Data, script: Data, notices: [String: Data] = [:], to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    for (name, bytes) in [("manifest.json", manifest), ("plugin.js", script)] + notices.sorted(by: { $0.key < $1.key }).map({ ($0.key, $0.value) }) {
      let file = directory.appendingPathComponent(name)
      try bytes.write(to: file, options: .atomic)
      try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
    }
  }
  public func installed() throws -> [InstalledPluginPackage] {
    var node = stat()
    if lstat(index.path, &node) != 0 {
      guard errno == ENOENT else { throw MTVError.message("插件安装清单不可读取") }
      return []
    }
    let data = try read("installed.json", at: root, maximum: 1_048_576)
    return try decodeInstalled(data)
  }
  private func decodeInstalled(_ data: Data) throws -> [InstalledPluginPackage] {
    let document = try JSONDecoder().decode(PluginInstallDocument.self, from: data)
    guard document.schema == 1, document.packages.count <= 32,
      Set(document.packages.map(\.id)).count == document.packages.count,
      Set(document.packages.map(\.receipt)).count == document.packages.count else { throw MTVError.message("插件安装清单无效") }
    if let seeds = document.seededExamples {
      guard seeds.count <= 256, Set(seeds).count == seeds.count,
        seeds.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw MTVError.message("Invalid example installation history") }
    }
    for package in document.packages { try validateExternal(package.manifest); try package.origin?.validate() }
    return document.packages
  }
  private func registryRecoveryBytes() throws -> Data {
    var node = stat()
    guard root.isFileURL, lstat(root.path, &node) == 0, node.st_mode & S_IFMT == S_IFDIR else {
      throw MTVError.message("插件管理目录不存在或被替换；未执行恢复")
    }
    return try PluginPackageFiles.read("installed.json", at: root, maximum: 1_048_576, allowEmpty: true)
  }
  public func reviewRegistryRecovery() throws -> PluginRegistryRecoveryReview {
    let bytes = try registryRecoveryBytes()
    let reason: String
    do { _ = try decodeInstalled(bytes); reason = "" }
    catch { reason = String(error.localizedDescription.prefix(600)) }
    guard !reason.isEmpty else { throw MTVError.message("插件安装清单正常，不需要重建") }
    return PluginRegistryRecoveryReview(registry: index, snapshot: bytes, reason: reason)
  }
  /// Serialized with installation in this actor. Preserves package files and
  /// sessions; only the reviewed invalid registry is removed after backup.
  public func commitRegistryRecovery(_ backup: PluginRegistryRecoveryBackup) throws {
    guard backup.registry == index, try registryRecoveryBytes() == backup.file.snapshot else {
      throw MTVError.message("插件清单已变化，请重新审阅；未清除新安装记录")
    }
    guard (try? decodeInstalled(backup.file.snapshot)) == nil else { throw MTVError.message("插件清单正常，未执行恢复") }
    try backup.file.verify()
    let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard directory >= 0 else { throw MTVError.message("插件管理目录已变化；未执行恢复") }
    defer { close(directory) }
    guard try registryRecoveryBytes() == backup.file.snapshot else {
      throw MTVError.message("插件清单已变化，请重新审阅；未清除新安装记录")
    }
    var opened = stat(), named = stat()
    guard fstat(directory, &opened) == 0, lstat(root.path, &named) == 0, named.st_mode & S_IFMT == S_IFDIR,
      opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
      unlinkat(directory, "installed.json", 0) == 0 else { throw MTVError.message("插件清单未能重建；备份与模块文件保留") }
    for id in Array(pending.keys) { cancel(id) }
  }
  private func save(_ packages: [InstalledPluginPackage], seededExamples requestedSeeds: [String]? = nil) throws {
    let seeds: [String]?
    if let requestedSeeds { seeds = requestedSeeds }
    else if FileManager.default.fileExists(atPath:index.path) {
      let data = try read("installed.json",at:root,maximum:1_048_576)
      _ = try decodeInstalled(data)
      seeds = try JSONDecoder().decode(PluginInstallDocument.self,from:data).seededExamples
    } else { seeds = nil }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let bytes = try encoder.encode(PluginInstallDocument(schema: 1, packages: packages,seededExamples:seeds))
    guard bytes.count <= 1_048_576 else { throw MTVError.message("插件安装清单超过大小限制") }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try bytes.write(to: index, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
  }
  /// App-shipped examples enter the ordinary managed store once. Removing or
  /// disabling an example is durable; restarting never resurrects it. Existing
  /// installed versions are not replaced by a bundle update.
  public func installExamplesOnce(from directory: URL, origin: PluginInstallationOrigin? = nil) throws {
    let catalog = try PluginCatalog.load(root:directory)
    guard catalog.issues.isEmpty else { throw MTVError.message("Example package validation failed") }
    var packages = try installed()
    var seeded: Set<String> = []
    if FileManager.default.fileExists(atPath:index.path) {
      let bytes = try read("installed.json",at:root,maximum:1_048_576)
      seeded = Set(try JSONDecoder().decode(PluginInstallDocument.self,from:bytes).seededExamples ?? [])
    }
    for example in catalog.plugins where !seeded.contains(example.id) {
      try validateExternal(example.manifest)
      if !packages.contains(where: { $0.id == example.id }) {
        let review = try prepare(directory:example.directory,origin:origin)
        _ = try approve(review.id)
        packages = try installed()
      }
      seeded.insert(example.id)
      try save(packages,seededExamples:seeded.sorted())
    }
  }
  public func prepare(directory: URL, origin: PluginInstallationOrigin? = nil) throws -> PluginInstallReview {
    try Task.checkCancellation()
    try origin?.validate()
    let packages = try installed()
    let (manifest, bytes, script) = try readPackage(directory)
    guard let symbol = manifest.presentation?.symbol, !symbol.isEmpty,
      NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
      ["en", "zh-Hans"].allSatisfy({ locale in
        guard let title = manifest.localizedNames?[locale] else { return false }
        return !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      }) else {
      throw MTVError.message(L("插件必须提供有效的图标和中英文标题"))
    }
    var notices: [String: Data] = [:]
    for name in ["LICENSE", "LICENSE.txt", "NOTICE", "README.md"] {
      var node = stat()
      if directory.appendingPathComponent(name).path.withCString({ lstat($0, &node) }) == 0 {
        let data = try PluginPackageFiles.read(name, at: directory, maximum: 65_536, allowEmpty: true)
        guard String(data: data, encoding: .utf8) != nil else { throw MTVError.message(L("插件授权文档必须是 UTF-8：") + name) }
        notices[name] = data
      }
    }
    guard packages.contains(where: { $0.id == manifest.id }) || packages.count < 32 else { throw MTVError.message("最多安装 32 个外部插件，请先移除不用的模块") }
    // Only one pending review; closing/replacing it removes its private staged copy.
    for id in Array(pending.keys) { cancel(id) }
    let id = UUID()
    let review = PluginInstallReview(id: id, manifest: manifest, source: directory.standardizedFileURL,
      replacingVersion: packages.first(where: { $0.id == manifest.id })?.manifest.version, noticeNames: notices.keys.sorted(),origin:origin)
    do { try writePackage(bytes, script: script, notices: notices, to: stage(id)) }
    catch { try? FileManager.default.removeItem(at: stage(id)); throw error }
    pending[id] = Pending(review: review, manifest: bytes, script: script, notices: notices)
    return review
  }
  public func cancel(_ id: UUID) {
    guard pending.removeValue(forKey: id) != nil else { return }
    try? FileManager.default.removeItem(at: stage(id))
  }
  @discardableResult public func approve(_ id: UUID) throws -> InstalledPluginPackage {
    guard let value = pending[id] else { throw MTVError.message("插件预览已过期，请重新选择目录") }
    let (_, manifest, script) = try readPackage(stage(id))
    guard manifest == value.manifest, script == value.script else { throw MTVError.message("待安装内容与已预览内容不同，请重新选择") }
    for (name, expected) in value.notices {
      guard try PluginPackageFiles.read(name, at: stage(id), maximum: 65_536, allowEmpty: true) == expected else { throw MTVError.message("授权文档与预览内容不同") }
    }
    var packages = try installed()
    let old = packages.first { $0.id == value.review.manifest.id }
    guard old != nil || packages.count < 32 else { throw MTVError.message("插件数量已达上限") }
    guard old?.manifest.version == value.review.replacingVersion else { throw MTVError.message("当前安装版本已变化，请重新预览") }
    var record = InstalledPluginPackage(receipt: UUID(), manifest: value.review.manifest, enabled: true, installedAt: Date())
    record.origin=value.review.origin
    let target = folder(record.receipt)
    do {
      try writePackage(manifest, script: script, notices: value.notices, to: target)
      packages.removeAll { $0.id == record.id }; packages.append(record)
      try save(packages)
    } catch { try? FileManager.default.removeItem(at: target); throw error }
    cancel(id)
    if let old { try? FileManager.default.removeItem(at: folder(old.receipt)) }
    return record
  }
  public func resolve(_ record: PluginRecord) throws -> PluginRecord {
    guard let package = try installed().first(where: { $0.id == record.id && $0.enabled }),
      record.directory.standardizedFileURL == folder(package.receipt).standardizedFileURL else { throw MTVError.message("插件未安装、已停用或安装位置不匹配") }
    var node = stat()
    guard record.directory.path.withCString({ lstat($0, &node) }) == 0, node.st_mode & S_IFMT == S_IFDIR else {
      throw MTVError.message("插件安装目录不能替换为符号链接")
    }
    let (manifest, bytes, _) = try readPackage(record.directory)
    guard bytes == (try Self.approvalBytes(package.manifest)), bytes == (try Self.approvalBytes(record.manifest)) else { throw MTVError.message("插件权限清单已变化，必须重新预览安装") }
    return PluginRecord(manifest: manifest, directory: record.directory)
  }
  public func catalog(developerMode: Bool = false) throws -> PluginCatalog {
    var plugins: [PluginRecord] = [], issues: [String] = []
    for package in try installed() where package.enabled {
      do {
        let record = try resolve(PluginRecord(manifest: package.manifest, directory: folder(package.receipt)))
        if record.manifest.presentation?.developerOnly != true || developerMode { plugins.append(record) }
      } catch { issues.append(package.manifest.name + "：" + error.localizedDescription) }
    }
    return PluginCatalog(plugins: plugins, issues: issues)
  }
  public func setEnabled(_ id: String, _ enabled: Bool) throws {
    var packages = try installed()
    guard let index = packages.firstIndex(where: { $0.id == id }) else { throw MTVError.message("插件不存在") }
    packages[index].enabled = enabled; try save(packages)
  }
  public func remove(_ id: String) throws {
    var packages = try installed()
    guard let old = packages.first(where: { $0.id == id }) else { return }
    packages.removeAll { $0.id == id }; try save(packages)
    try? FileManager.default.removeItem(at: folder(old.receipt))
  }
}

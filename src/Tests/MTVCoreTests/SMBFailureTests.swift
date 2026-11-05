import Darwin
import Foundation
import Testing
@testable import MTVCore

struct SMBFailureTests {
  @Test func selectedDirectoryUsesCanonicalShareRelativePath() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = root.appendingPathComponent("影片 # 100%/第二季")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: folder)
    let selection = try SMBDirectoryAccess.selection(in: root.appendingPathComponent("alias"), allowedRoot: root)
    #expect(selection.directory.path == folder.resolvingSymlinksInPath().path)
    #expect(selection.relativePath == "/影片 # 100%/第二季")
    #expect(try SMBDirectoryAccess.selection(in: root, allowedRoot: root).relativePath == "")
    var address = URLComponents(string: "smb://nas/Movies")!
    address.path += selection.relativePath
    let location = try SMBLocation(address.url!.absoluteString)
    #expect(location.subdirectory == ["影片 # 100%", "第二季"])
  }
  @Test func selectedDirectoryRejectsSymlinkMovedOutsideAfterBrowsing() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("folder"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    let alias = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root.appendingPathComponent("folder"))
    _ = try SMBDirectoryAccess.children(in: root, allowedRoot: root)
    try FileManager.default.removeItem(at: alias)
    try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: outside)
    #expect(throws: (any Error).self) { try SMBDirectoryAccess.selection(in: alias, allowedRoot: root) }
  }
  @Test func selectedDirectoryRechecksRemovedFolderAndRegularFile() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let folder = root.appendingPathComponent("folder")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try SMBDirectoryAccess.children(in: root, allowedRoot: root)
    try FileManager.default.removeItem(at: folder)
    do { _ = try SMBDirectoryAccess.selection(in: folder, allowedRoot: root); Issue.record("Removed folder selected") }
    catch let failure as SMBFailure { #expect(failure.category == .missing && failure.stage == .directoryVerification) }
    try Data("owned".utf8).write(to: folder)
    do { _ = try SMBDirectoryAccess.selection(in: folder, allowedRoot: root); Issue.record("Regular file selected") }
    catch let failure as SMBFailure { #expect(failure.category == .notDirectory && failure.stage == .directoryVerification) }
  }
  @Test func permissionEvidenceRetainsOnlyCodesWithoutClaimingTCCOrBadPassword() {
    let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM), userInfo: [NSLocalizedDescriptionKey: "secret-password", NSURLErrorKey: URL(string: "smb://user:secret@host/share")!])
    let error = NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileReadNoPermission.rawValue, userInfo: [NSUnderlyingErrorKey: underlying])
    let failure = SMBFailure(error, stage: .directoryRead)
    #expect(failure.category == .accessDenied && failure.stage == .directoryRead)
    #expect(failure.codes.map(\.value) == [257, Int(EPERM)])
    #expect(failure.errorDescription?.contains("无法区分") == true)
    #expect(!failure.diagnostic.contains("secret") && !failure.diagnostic.contains("smb://"))
    #expect(SMBFailure(failure, stage: .mount) == failure)
  }
  @Test func mountPermissionAndUnknownStatusAreNotMisreportedAsAuthentication() {
    #expect(SMBFailure.netFS(EAUTH).category == .authentication)
    #expect(SMBFailure.netFS(EACCES).category == .accessDenied)
    #expect(SMBFailure.netFS(-6004).category == .other)
    #expect(SMBFailure.netFS(-6004).codes.first?.domain == NSOSStatusErrorDomain)
    #expect(SMBFailure.netFS(-6004).codes.first?.value == -6004)
    #expect(SMBFailure.netFS(ETIMEDOUT).category == .timeout)
    #expect(SMBFailure.netFS(ECONNRESET).category == .network)
  }
  @Test func nativeDirectoryVerificationDistinguishesMissingAndNonDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try SMBDirectoryAccess.requireDirectory(root)
    let file = root.appendingPathComponent("file"); try Data("owned fixture".utf8).write(to: file)
    do { try SMBDirectoryAccess.requireDirectory(file); Issue.record("Regular file accepted as a directory") }
    catch let failure as SMBFailure { #expect(failure.category == .notDirectory && failure.stage == .directoryVerification) }
    do { try SMBDirectoryAccess.requireDirectory(root.appendingPathComponent("missing")); Issue.record("Missing directory accepted") }
    catch let failure as SMBFailure { #expect(failure.category == .missing && !failure.codes.isEmpty) }
  }
  @Test func directoryEnumerationKeepsBoundsHiddenFilterAndFiniteList() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
    for index in 0..<205 { try FileManager.default.createDirectory(at: root.appendingPathComponent("Folder-\(index)"), withIntermediateDirectories: true) }
    try FileManager.default.createDirectory(at: root.appendingPathComponent(".hidden"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
    let result = try SMBDirectoryAccess.children(in: root, allowedRoot: root)
    #expect(result.folders.count == 200)
    #expect(result.folders.first?.lastPathComponent == "Folder-0")
    #expect(!result.folders.contains { [".hidden", "escape"].contains($0.lastPathComponent) })
    #expect(throws: (any Error).self) { try SMBDirectoryAccess.children(in: root.appendingPathComponent("escape"), allowedRoot: root) }
    do { _ = try SMBDirectoryAccess.children(in: root.appendingPathComponent("missing"), allowedRoot: root); Issue.record("Missing directory listed") }
    catch let failure as SMBFailure { #expect(failure.stage == .directoryRead && failure.category == .missing) }
  }
  @Test func diagnosticChainIsBoundedAndStripsControlCharacters() {
    var error = NSError(domain: "test\n\u{0}domain", code: 0)
    for index in 1..<20 { error = NSError(domain: String(repeating: "d", count: 300), code: index, userInfo: [NSUnderlyingErrorKey: error]) }
    let failure = SMBFailure(error, stage: .mount)
    #expect(failure.codes.count == 4 && failure.codes.allSatisfy { $0.domain.count <= 64 })
    #expect(!failure.diagnostic.contains("\n") && !failure.diagnostic.contains("\u{0}"))
  }
}

import Darwin
import Foundation
import Testing
@testable import MTVCore

struct LocalControlTests {
  private func directory() -> URL { URL(fileURLWithPath: "/tmp/mtv-ctl-" + UUID().uuidString.prefix(12)) }
  private func send(_ request: LocalControlRequest, root: URL) async throws -> [String: Any] {
    let data: Data = try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global().async {
        do { continuation.resume(returning: try LocalControlClient.send(request, root: root)) }
        catch { continuation.resume(throwing: error) }
      }
    }
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  }
  private func reply(_ request: LocalControlRequest) -> Data {
    LocalControlJSON.encode(["schema": 1, "id": request.id.uuidString, "ok": true, "command": request.command])
  }
  @Test func socketRoundtripIsPrivateAndCannotReplaceLiveServer() async throws {
    let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
    let server = LocalControlServer(root: root); defer { server.stop() }
    try server.start { request in reply(request) }
    // This checks socket ownership/permissions, not scheduler latency. Deadline
    // rejection is verified separately; keep this fixture within the public cap.
    let request = LocalControlRequest(command: "status",timeout:25)
    let response = try await send(request, root: root)
    #expect(response["ok"] as? Bool == true)
    #expect(response["id"] as? String == request.id.uuidString)
    #expect(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int == 0o700)
    let socket = root.appendingPathComponent("control.sock")
    #expect(try FileManager.default.attributesOfItem(atPath: socket.path)[.posixPermissions] as? Int == 0o600)
    let duplicate = LocalControlServer(root: root)
    #expect(throws: (any Error).self) { try duplicate.start { request in reply(request) } }
    #expect(try await send(LocalControlRequest(command: "status"), root: root)["ok"] as? Bool == true)
    try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: socket.path)
    await #expect(throws: (any Error).self) { try await send(request, root: root) }
  }
  @Test func invalidAndExpiredRequestsDoNotInvokeHandler() async throws {
    let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
    let server = LocalControlServer(root: root); defer { server.stop() }
    let count = ControlTestCounter()
    try server.start { request in await count.increment(); return reply(request) }
    let response = try await send(LocalControlRequest(command: "status", timeout: -1), root: root)
    #expect(response["ok"] as? Bool == false)
    #expect(await count.value == 0)
    #expect(throws: (any Error).self) { try LocalControlRequest(command: "status\ncommand").validate() }
    #expect(throws: (any Error).self) { try LocalControlRequest(command: "status", arguments: ["a": String(repeating: "x", count: 8193)]).validate() }
    #expect(throws: (any Error).self) { try LocalControlRequest(command: "status", timeout: 90).validate() }
  }
  @Test func regularFilesAndSymlinkDirectoriesAreNeverConsumedAsEndpoints() throws {
    let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
    try LocalControlPaths.prepare(root)
    let file = root.appendingPathComponent("control.sock")
    try Data("keep".utf8).write(to: file)
    let server = LocalControlServer(root: root)
    #expect(throws: (any Error).self) { try server.start { request in reply(request) } }
    #expect(try String(contentsOf: file, encoding: .utf8) == "keep")
    let link = root.appendingPathComponent("alias")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    #expect(throws: (any Error).self) { try LocalControlPaths.prepare(link) }
  }
  @Test func textSnapshotsReplaceTheirOwnLinkAndPreserveOutsideFiles() throws {
    let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
    try LocalControlPaths.prepare(root)
    let outside = root.appendingPathComponent("original")
    try Data("original".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("state.json"), withDestinationURL: outside)
    try LocalControlPaths.write(Data("{}".utf8), name: "state.json", root: root)
    #expect(try String(contentsOf: outside, encoding: .utf8) == "original")
    #expect(try String(contentsOf: root.appendingPathComponent("state.json"), encoding: .utf8) == "{}")
    #expect(try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("state.json").path)[.posixPermissions] as? Int == 0o600)
    #expect(throws: (any Error).self) { try LocalControlPaths.write(Data(), name: "../outside", root: root) }
  }
  @Test func controlLogsRedactURLsTokensAndCookieFields() {
    let jwt = ["eyJ" + String(repeating: "a", count: 20), String(repeating: "b", count: 20), String(repeating: "c", count: 20)].joined(separator: ".")
    let value = LocalControlJSON.safeText("failure https://media.example/file?signature=private SESSDATA=secret; __kps=second Authorization: Bearer " + jwt)
    #expect(!value.contains("signature"))
    #expect(!value.contains("secret"))
    #expect(!value.contains("second"))
    #expect(!value.contains(jwt))
    #expect(!LocalControlJSON.safeText("smb://demo:fixture-only@nas.example/share").contains("fixture-only"))
    #expect(LocalControlJSON.safeText("等待系统授权") == "等待系统授权")
  }
  @Test func visualExportIsPrivateAndDoesNotAcceptNonPNG() throws {
    let root = directory(); defer { try? FileManager.default.removeItem(at: root) }
    #expect(throws: (any Error).self) { try LocalControlPaths.writeVisual(Data("not-an-image".utf8), root: root) }
    let header = Data([137,80,78,71,13,10,26,10])
    let first = try LocalControlPaths.writeVisual(header, root: root)
    let second = try LocalControlPaths.writeVisual(header, root: root)
    #expect(first != second && first.pathExtension == "png")
    #expect(try FileManager.default.attributesOfItem(atPath: first.path)[.posixPermissions] as? Int == 0o600)
    #expect(try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? Int == 0o700)
  }
}

private actor ControlTestCounter {
  private(set) var value = 0
  func increment() { value += 1 }
}

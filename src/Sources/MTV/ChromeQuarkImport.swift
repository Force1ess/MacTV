import AppKit
import Foundation
import MTVCore

enum ChromeQuarkImport {
  static let hostName = "local.mtv.quark_bridge"
  static func installConnector() throws -> URL {
    guard let resources = Bundle.main.resourceURL, let executable = Bundle.main.executableURL else { throw MTVError.message("应用包不完整") }
    let bridge = executable.deletingLastPathComponent().appendingPathComponent("MTVChromeBridge")
    guard FileManager.default.isExecutableFile(atPath: bridge.path) else { throw MTVError.message("缺少Chrome登录连接组件，请更新MacTV") }
    let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Google/Chrome/NativeMessagingHosts", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let manifest: [String: Any] = ["name": hostName, "description": "MacTV Quark session import", "type": "stdio",
      "path": bridge.path, "allowed_origins": [ChromeQuarkSessionImport.origin]]
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
      .write(to: directory.appendingPathComponent(hostName + ".json"), options: .atomic)
    return resources.appendingPathComponent("ChromeQuarkBridge", isDirectory: true)
  }
  /// Chrome native-messaging framing. No credentials are written to stdout/stderr.
  static func runNativeMessage() {
    func reply(_ ok: Bool) {
      let data = Data((ok ? "{\"ok\":true}" : "{\"ok\":false}").utf8)
      var length = UInt32(data.count).littleEndian
      FileHandle.standardOutput.write(withUnsafeBytes(of: &length) { Data($0) })
      FileHandle.standardOutput.write(data)
    }
    func read(_ count: Int) throws -> Data {
      var data = Data()
      while data.count < count {
        guard let piece = try FileHandle.standardInput.read(upToCount: count - data.count), !piece.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        data.append(piece)
      }
      return data
    }
    guard CommandLine.arguments.dropFirst(2).first == ChromeQuarkSessionImport.origin else { reply(false); return }
    do {
      let prefix = try read(4), count = prefix.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
      guard count > 0, count <= 32768 else { reply(false); return }
      let payload = try read(Int(count))
      let done = DispatchSemaphore(value: 0)
      let task = Task.detached {
        defer { done.signal() }
        do {
          let session = try ChromePlatformSession.decode(payload)
          let folder = session.pluginID == "mtv.quark" ? "quark" : "bilibili"
          guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
          let manifest = try JSONDecoder().decode(PluginManifest.self,
            from: Data(contentsOf: resources.appendingPathComponent("plugins/" + folder + "/manifest.json")))
          try session.validate(for: manifest)
          let verified = try await ChromePlatformSession.verify(session)
          try verified.validate(for: manifest)
          try Task.checkCancellation()
          try PluginSessionStore().save(verified)
          reply(true)
        } catch { reply(false) }
      }
      if done.wait(timeout: .now() + 20) == .timedOut { task.cancel() }
    } catch { reply(false) }
  }
}

extension LoginController {
  func importChromeSession() {
    guard supportsChromeImport else { return }
    beginLocalChromeImport()
  }
}

import Foundation
import CoreGraphics
import MTVCore

@main struct AuthProbe {
  static func main() {
    if CommandLine.arguments == [CommandLine.arguments[0], "--system-authorization-windows"] {
      let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
      let values = windows.filter { ["SecurityAgent", "SecurityAgentHelper", "loginwindow"].contains($0[kCGWindowOwnerName as String] as? String ?? "") }.map { value in
        ["owner": value[kCGWindowOwnerName as String] ?? "", "pid": value[kCGWindowOwnerPID as String] ?? 0,
          "bounds": value[kCGWindowBounds as String] ?? [:], "layer": value[kCGWindowLayer as String] ?? 0] as [String: Any]
      }
      if let bytes = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) { print(String(decoding: bytes, as: UTF8.self)) }
      return
    }
    if CommandLine.arguments == [CommandLine.arguments[0], "--chrome-access"] {
      let value = ChromeStorageAccess.inspect()
      do { print(String(decoding: try JSONEncoder().encode(value), as: UTF8.self)) }
      catch { print("{\"error\":\"metadata-encoding-failed\",\"secretRead\":false}"); exit(1) }
      return
    }
    if CommandLine.arguments.contains("--chrome-bridge-test") { chromeBridgeTest(); return }
    let identifier = "test." + UUID().uuidString.lowercased()
    let store = PluginSessionStore(service: "local.mtv.preview.tests." + UUID().uuidString)
    var created = false
    defer { if created { try? store.remove(pluginID: identifier) } }
    do {
      var checks: [String: Bool] = [:]
      checks["missingOwnRecordIsEmpty"] = try store.load(pluginID: identifier) == nil
      let first = PluginSession(
        pluginID: identifier, domains: ["api.example.test"], cookie: "sid=TEST_ONLY_A")
      try store.save(first)
      created = true
      checks["roundtripOwnTestRecord"] =
        try store.load(pluginID: identifier)?.cookie == first.cookie
      let second = PluginSession(
        pluginID: identifier, domains: ["api.example.test"], cookie: "sid=TEST_ONLY_B")
      try store.save(second)
      checks["updateOwnTestRecord"] = try store.load(pluginID: identifier)?.cookie == second.cookie
      checks["otherModuleDoesNotMatch"] = try store.load(pluginID: "other." + identifier) == nil
      try store.remove(pluginID: identifier)
      created = false
      checks["removeOwnTestRecord"] = try store.load(pluginID: identifier) == nil
      let result: [String: Any] = [
        "checks": checks, "passed": checks.values.allSatisfy { $0 }, "realAccountRead": false,
      ]
      let data = try JSONSerialization.data(
        withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      print(String(data: data, encoding: .utf8)!)
      exit(checks.values.allSatisfy { $0 } ? 0 : 1)
    } catch {
      let data = try! JSONSerialization.data(
        withJSONObject: [
          "passed": false, "error": error.localizedDescription, "realAccountRead": false,
        ], options: [.prettyPrinted])
      print(String(data: data, encoding: .utf8)!)
      exit(1)
    }
  }
  static func chromeBridgeTest() {
    do {
      var checks: [String: Bool] = [:]
      let marker = "MTV_IMPORT_FIXTURE_NOT_A_REAL_COOKIE"
      for (name, origin, payload) in [
        ("wrongOrigin", "chrome-extension://aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/", ["schema": 1] as [String: Any]),
        ("wrongDomain", ChromeQuarkSessionImport.origin, ["schema": 1, "provider": "mtv.quark", "cookies": [["name": "__pus", "value": marker, "domain": ".example.com", "path": "/", "hostOnly": false]]]),
        ("expired", ChromeQuarkSessionImport.origin, ["schema": 1, "provider": "mtv.quark", "cookies": [["name": "__pus", "value": marker, "domain": ".quark.cn", "path": "/", "hostOnly": false, "expirationDate": 1]]])
      ] {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/Applications/MacTV.app/Contents/MacOS/MTVChromeBridge")
        process.arguments = [origin]; process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = try JSONSerialization.data(withJSONObject: payload)
        var count = UInt32(data.count).littleEndian
        input.fileHandleForWriting.write(withUnsafeBytes(of: &count) { Data($0) })
        input.fileHandleForWriting.write(data); try input.fileHandleForWriting.close()
        let reply = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let validPrefix = reply.count >= 4 && reply.count < 128
        let length = validPrefix ? reply.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } : 0
        let body = validPrefix ? Data(reply.dropFirst(4)) : Data()
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Bool]
        checks[name + "Rejected"] = process.terminationStatus == 0 && Int(length) == body.count && object?["ok"] == false
        checks[name + "NeverEchoesSecret"] = !String(decoding: reply, as: UTF8.self).contains(marker)
      }
      print(String(decoding: try JSONSerialization.data(withJSONObject: ["checks": checks, "passed": checks.values.allSatisfy { $0 }, "realAccountRead": false], options: [.sortedKeys]), as: UTF8.self))
      exit(checks.values.allSatisfy { $0 } ? 0 : 1)
    } catch { print("{\"passed\":false,\"realAccountRead\":false}"); exit(1) }
  }
}

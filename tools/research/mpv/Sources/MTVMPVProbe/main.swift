import AppKit
import Foundation
import MPVBridge

private func command(_ player: OpaquePointer, _ values: [String]) -> Int32 {
  let strings = values.map { strdup($0) }
  defer { strings.forEach { free($0) } }
  let pointers: [UnsafePointer<CChar>?] = strings.map { $0.map { UnsafePointer($0) } } + [nil]
  return pointers.withUnsafeBufferPointer { probe_mpv_command(player, $0.baseAddress) }
}
private func property(_ player: OpaquePointer, _ name: String) -> String {
  var result = [CChar](repeating: 0, count: 8192)
  guard probe_mpv_property(player, name, &result, Int32(result.count)) == 0 else { return "" }
  return String(cString: result)
}
@MainActor final class Probe: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    let inspectAudio = CommandLine.arguments.contains("--inspect-audio")
    let audioDevice = CommandLine.arguments.first { $0.hasPrefix("--audio-device=") }.map { String($0.dropFirst("--audio-device=".count)) }
    let args = CommandLine.arguments.filter { $0 != "--inspect-audio" && !$0.hasPrefix("--audio-device=") }
    guard args.count == 5, !inspectAudio || args[4] == "null" else { exit(2) }
    let output = URL(fileURLWithPath: args[3], isDirectory: true)
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    Task.detached {
      var report: [String: Any] = ["sourceUnmodified": true, "muted": true, "requestedVO": args[4], "productionIntegration": false,
        "audioInspection": inspectAudio, "physicalAudioVerified": false]
      guard let player = probe_mpv_create(args[1]) else {
        report["error"] = String(cString: probe_mpv_error()); Self.save(report, output)
        await MainActor.run { NSApp.terminate(nil) }; return
      }
      var options = ["config":"no", "vo":args[4], "mute":"yes", "volume":"0", "osc":"no", "osd-level":"0",
        "input-default-bindings":"no", "input-vo-keyboard":"no", "input-cursor":"no", "resume-playback":"no",
        "save-position-on-quit":"no", "hwdec":"auto-safe", "start":"60", "force-window":"yes",
        "screenshot-format":"png", "geometry":"960x540", "log-file":output.appendingPathComponent("mpv.log").path]
      if inspectAudio {
        options["start"] = "0"; options["ao"] = "null"
        options["alang"] = "zho,chi,zh,eng"; options["force-window"] = "no"
        if let audioDevice { options.removeValue(forKey: "ao"); options["audio-device"] = audioDevice }
      }
      var rejected: [String] = []
      for (key, value) in options { if probe_mpv_option(player,key,value) < 0 { rejected.append(key) } }
      report["rejectedOptions"] = rejected
      report["initializeStatus"] = probe_mpv_initialize(player)
      report["loadStatus"] = command(player, ["loadfile", args[2], "replace"])
      var timelineAdvanced = false
      for _ in 0..<150 {
        if (Double(property(player,"time-pos")) ?? 0) > (inspectAudio ? 2 : 62) { timelineAdvanced = true; break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      report["pauseStatus"] = command(player,["set","pause","yes"])
      if !inspectAudio { report["exactSeekStatus"] = command(player,["seek","62","absolute+exact"]) }
      try? await Task.sleep(for: .milliseconds(800))
      for key in ["mpv-version", "current-vo", "time-pos", "duration", "video-codec", "video-params", "video-out-params", "hwdec-current", "video-format", "audio-codec-name"] {
        report[key] = property(player,key)
      }
      if inspectAudio {
        for key in ["track-list", "aid", "current-ao", "audio-pts", "audio-out-params"] { report[key] = property(player,key) }
      } else {
        report["windowScreenshotStatus"] = command(player,["screenshot-to-file", output.appendingPathComponent("rendered-window.png").path,"window"])
        report["videoScreenshotStatus"] = command(player,["screenshot-to-file", output.appendingPathComponent("video.png").path,"video"])
      }
      report["timelineAdvanced"] = timelineAdvanced
      Self.save(report,output)
      probe_mpv_destroy(player)
      await MainActor.run { NSApp.terminate(nil) }
    }
  }
  nonisolated static func save(_ report: [String: Any], _ output: URL) {
    if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("result.json"))
    }
  }
}
MainActor.assumeIsolated {
  let app = NSApplication.shared, delegate = Probe()
  app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
  withExtendedLifetime(delegate) {}
}

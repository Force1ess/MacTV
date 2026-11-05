import AppKit
import AVFoundation
import KSPlayer

// A maintained isolated compatibility probe, not an alternate production player.
// It never updates media, playback history, system audio routing or app settings.
@MainActor final class Probe: NSObject, NSApplicationDelegate {
  var window: NSWindow?
  var player: KSMEPlayer?
  func applicationDidFinishLaunching(_ notification: Notification) {
    guard CommandLine.arguments.count == 3 else { exit(2) }
    let file = URL(fileURLWithPath: CommandLine.arguments[1])
    let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
    guard FileManager.default.fileExists(atPath: file.path) else { exit(2) }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    window.title = "MTV 色彩兼容验证"; self.window = window
    let player = KSMEPlayer(url: file, options: KSOptions())
    self.player = player; player.isMuted = true
    if let view = player.view { window.contentView = view }
    window.center(); window.makeKeyAndOrderFront(nil)
    player.prepareToPlay(); player.play()
    Task { @MainActor in
      for _ in 0..<100 {
        if player.isReadyToPlay, player.currentPlaybackTime > 2 { break }
        try? await Task.sleep(for: .milliseconds(200))
      }
      try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
      let frame = await player.thumbnailImageAtCurrentTime()
      if let frame, let png = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:]) {
        try? png.write(to: output.appendingPathComponent("decoded-frame.png"))
      }
      if let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: output.appendingPathComponent("window.png"))
      }
      let report: [String: Any] = ["ready": player.isReadyToPlay, "position": player.currentPlaybackTime,
        "duration": player.duration, "decodedFrame": frame != nil, "muted": player.isMuted,
        "sourceUnmodified": true, "productionIntegration": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("result.json"))
      }
      player.shutdown(); NSApp.terminate(nil)
    }
  }
}
MainActor.assumeIsolated {
  let app = NSApplication.shared
  let delegate = Probe()
  app.delegate = delegate; app.setActivationPolicy(.accessory); app.run()
  withExtendedLifetime(delegate) {}
}

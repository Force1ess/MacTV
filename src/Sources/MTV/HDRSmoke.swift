import AVFoundation
import AVKit
import AppKit
import MTVCore

extension UISmoke {
  static func hdrSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    let engine = model.preferredEngine
    let preference = model.videoPresentation.preference
    defer {
      model.stopPlayback(); model.preferredEngine = engine
      model.videoPresentation.setPreference(preference); model.notice = nil
    }
    var checks: [String: Bool] = [:]
    var diagnostics: [String: Any] = ["physicalHDROutputVerified": false, "dolbyOutputVerified": false]
    func nativeView(_ view: NSView?) -> AVPlayerView? {
      guard let view else { return nil }
      if let player = view as? AVPlayerView { return player }
      for child in view.subviews { if let found = nativeView(child) { return found } }
      return nil
    }
    let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/MTV/Fixtures/HDR-v1")
    model.preferredEngine = .system
    model.videoPresentation.setPreference(.automatic)
    for (name, transfer, dolby) in [("HLG", "ITU_R_2100_HLG", false), ("PQ", "SMPTE_ST_2084_PQ", false),
      ("HLG-Auto", "ITU_R_2100_HLG", true)] {
      let url = root.appendingPathComponent(name + ".mp4")
      model.beginPlayback(url: url, item: MediaItem(id: "hdr-fixture-" + name, title: "Generated " + name, url: url.absoluteString))
      for _ in 0..<150 {
        if model.player?.currentItem?.status == .readyToPlay && model.videoPresentation.signal != nil { break }
        try? await Task.sleep(for: .milliseconds(40))
      }
      let signal = model.videoPresentation.signal
      checks["hdr\(name)SourceSignal"] = signal?.transferFunction == transfer
        && signal?.containsHDR == true && signal?.width == 640 && signal?.height == 360
        && signal?.dolbyVisionSignaled == dolby
      checks["hdr\(name)PerFrameMetadataRetained"] = model.player?.currentItem?.appliesPerFrameHDRDisplayMetadata == true
      if let signal, let bytes = try? JSONEncoder().encode(signal),
        let object = try? JSONSerialization.jsonObject(with: bytes) { diagnostics[name + "Source"] = object }
      let decoder = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
      ])
      let item = model.player?.currentItem
      item?.add(decoder)
      var decoded: CVPixelBuffer?
      for _ in 0..<125 {
        if let player = model.player, let buffer = decoder.copyPixelBuffer(forItemTime: player.currentTime(), itemTimeForDisplay: nil) {
          decoded = buffer; break
        }
        try? await Task.sleep(for: .milliseconds(20))
      }
      checks["hdr\(name)Decoded10BitFrame"] = decoded.map {
        CVPixelBufferGetPixelFormatType($0) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
          && CVPixelBufferGetWidth($0) == 640 && CVPixelBufferGetHeight($0) == 360
      } == true
      if let decoded {
        let attachments = (CVBufferCopyAttachments(decoded, .shouldPropagate) as? [String: Any]) ?? [:]
        if dolby {
          // Observed on this sdk/runtime; diagnostic assertion, never a production switch.
          let rpu = attachments["DolbyVisionRPUData"] as? Data
          checks["hdrDolbyDecodedCarriesObservedRPUData"] = rpu?.isEmpty == false
          diagnostics["observedDolbyRPUBytes"] = rpu?.count ?? 0
        }
        var distinctLuma = 0
        if CVPixelBufferGetPixelFormatType(decoded) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
          CVPixelBufferLockBaseAddress(decoded, .readOnly) == kCVReturnSuccess {
          if let base = CVPixelBufferGetBaseAddressOfPlane(decoded, 0) {
            let stride = CVPixelBufferGetBytesPerRowOfPlane(decoded, 0) / 2
            let row = CVPixelBufferGetHeightOfPlane(decoded, 0) / 2
            let pixels = base.assumingMemoryBound(to: UInt16.self)
            distinctLuma = Set((0..<CVPixelBufferGetWidthOfPlane(decoded, 0)).map {
              pixels[row * stride + $0] >> 6
            }).count
          }
          CVPixelBufferUnlockBaseAddress(decoded, .readOnly)
        }
        checks["hdr\(name)DecodedRampExceeds8BitLumaLevels"] = distinctLuma > 256
        diagnostics[name + "Decoded"] = ["pixelFormat": CVPixelBufferGetPixelFormatType(decoded),
          "distinctLumaInMiddleRow": distinctLuma,
          "transfer": attachments[kCVImageBufferTransferFunctionKey as String] as? String ?? "unavailable",
          "primaries": attachments[kCVImageBufferColorPrimariesKey as String] as? String ?? "unavailable",
          "attachmentKeys": attachments.keys.sorted()]
      }
      item?.remove(decoder)
      if name == "HLG" {
        model.showPlayerControls()
        checks["diagnosticVideoOptionsRemovedFromPlaybackBar"] = !model.playerControlIndices.contains(6)
        // Keep actual AV output-mode validation as an internal diagnostic;
        // normal users no longer see this technical panel in the playback bar.
        model.playerCommand(6)
        await settle()
        capture(window, to: output.appendingPathComponent("35-video-presentation.png"))
        if let display = model.videoPresentation.display, let bytes = try? JSONEncoder().encode(display),
          let object = try? JSONSerialization.jsonObject(with: bytes) { diagnostics["display"] = object }
        model.handle(.back)
        checks["videoOptionsBackKeepsPlayback"] = !model.videoPresentation.isPresented && model.player?.currentItem === item
        if #available(macOS 26.0, *) {
          for choice in [VideoRangeChoice.standard, .high, .automatic] {
            model.playerCommand(6)
            for _ in 0..<3 { model.handle(.up) }
            for _ in 0..<(VideoRangeChoice.allCases.firstIndex(of: choice) ?? 0) { model.handle(.down) }
            model.handle(.select)
            await settle()
            checks["nativeVideoRangeApplied-\(choice.rawValue)"] = model.videoPresentation.preference == choice
              && nativeView(window.contentView)?.preferredDisplayDynamicRange == choice.avDisplayRange
              && model.player?.currentItem === item && !model.videoPresentation.isPresented
          }
        }
      }
      model.stopPlayback()
    }
    if VLCPlaybackEngine.isAvailable {
      model.preferredEngine = .vlc
      let fixture = root.deletingLastPathComponent().appendingPathComponent("PlaybackFixture.mp4")
      model.beginPlayback(url: fixture, item: MediaItem(id: "hdr-options-vlc", title: "Generated VLC", url: fixture.absoluteString))
      for _ in 0..<100 {
        if model.vlcEngine != nil { break }
        try? await Task.sleep(for: .milliseconds(20))
      }
      let vlc = model.vlcEngine
      model.playerCommand(6)
      checks["vlcVideoOptionsDoNotApplyNativeModes"] = model.videoPresentation.isPresented
        && !model.videoPresentation.supportsModes && model.videoPresentation.count == 1
        && model.videoPresentation.signal == nil
      model.handle(.back)
      checks["vlcVideoOptionsBackKeepsPlayback"] = vlc != nil && model.vlcEngine === vlc
    }
    if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("hdr-signals.json"), options: .atomic)
    }
    return checks
  }
}

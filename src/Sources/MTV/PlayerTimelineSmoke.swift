import AppKit
import AVFoundation
import MTVCore

extension UISmoke {
  static func playerTimelineSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    var checks: [String: Bool] = [:], observations: [String: Any] = [:]
    let preference = model.preferredEngine
    defer { model.stopPlayback(); model.preferredEngine = preference; model.notice = nil; model.navigate(.home) }
    func wait(_ condition: () -> Bool) async {
      for _ in 0..<300 { if condition() { return }; try? await Task.sleep(for: .milliseconds(40)) }
    }
    func clock() async -> Double {
      if let engine = model.mpvEngine { return Double(await engine.diagnostic("time-pos")) ?? -100 }
      if let engine = model.vlcEngine { return engine.latest?.elapsed ?? -100 }
      return model.player?.currentTime().seconds ?? -100
    }
    func backendPaused() -> Bool {
      if let engine = model.mpvEngine { return engine.latest?.paused == true }
      if let engine = model.vlcEngine { return engine.latest?.state == 4 }
      return model.player?.rate == 0
    }
    func stop() async {
      let vlc = model.vlcEngine, mpv = model.mpvEngine
      model.stopPlayback(); await vlc?.waitUntilStopped(); await mpv?.waitUntilStopped()
    }
    func hostingView(_ view: NSView?) -> NSView? {
      guard let view else { return nil }
      let name = String(describing: type(of: view))
      if name.contains("NSHostingView") || name.contains("MPVTransparentHost") { return view }
      for child in view.subviews { if let host = hostingView(child) { return host } }
      return nil
    }
    func nativeSlider(_ view: NSView?) -> NSView? {
      guard let view else { return nil }
      if (view is NSSlider || String(describing: Swift.type(of: view)) == "CustomMarkedSlider"), view.bounds.width > 100, !view.isHidden { return view }
      for child in view.subviews { if let found = nativeSlider(child) { return found } }
      return nil
    }
    let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/IndependentLongGOP45-v1.mp4")
    // The ordinary app supports automatic system/MPV playback and no longer
    // ships VLC. Historical VLC tools remain separate from this current UI gate.
    for choice in [PlaybackEngineChoice.system, .mpv] {
      await stop(); model.preferredEngine = choice; model.notice = nil
      let id = "owned-timeline-" + choice.rawValue
      let overview = String(repeating: "Browse the story while keeping the picture visible. Use the progress bar to seek, then keep adjusting without leaving the timeline. ", count: 4)
      model.beginPlayback(url: file, item: MediaItem(id: id, title: "进度条交互验证", overview: overview, url: file.absoluteString), fromBeginning: true)
      await wait { model.playingItem?.id == id && model.playbackPresented && model.elapsed > 0.5 }
      model.playerCommand(1); await wait { backendPaused() }
      let initial = await clock()
      checks[choice.rawValue + "-noExitButtonInRemoteControls"] = !model.playerControlIndices.contains(5)
      model.playerControlsVisible = false; model.handle(.right)
      checks[choice.rawValue + "-hiddenArrowEntersPreviewWithoutClick"] = model.playerScrub != nil && model.playerControlsVisible
      model.handle(.back)
      model.handle(.up)
      checks[choice.rawValue + "-hiddenUpFocusesTimelineInOneAction"] = model.playerScrub != nil && model.playerControlsVisible
      model.handle(.down)
      checks[choice.rawValue + "-downReturnsToPlayButton"] = model.playerScrub == nil && model.playerButton == 1

      model.showPlayerControls(); model.handle(.up); model.handle(.right)
      let preview = model.playerScrub?.position ?? -100
      try? await Task.sleep(for: .milliseconds(200))
      let afterPreview = await clock()
      checks[choice.rawValue + "-remoteFocusAndPreview"] = model.playerScrub != nil && abs(preview - initial - 10) < 0.2
      checks[choice.rawValue + "-previewDoesNotMoveBackend"] = abs(afterPreview - initial) < 0.1
      model.handle(.back)
      checks[choice.rawValue + "-backCancelsPreviewAndHidesWithoutExit"] = model.playerScrub == nil && model.playbackPresented && !model.playerControlsVisible
      model.showPlayerControls(); model.handle(.up); model.handle(.right)
      let target = model.playerScrub?.position ?? -100
      model.handle(.select); await wait { abs(model.elapsed - target) < 0.3 }
      let remoteSeek = await clock()
      checks[choice.rawValue + "-confirmSeeksActualClock"] = abs(remoteSeek - target) < 0.3 && model.playerScrub == nil && model.paused
      checks[choice.rawValue + "-confirmKeepsTimelineFocused"] = model.playerTimelineFocused
      model.handle(.right)
      checks[choice.rawValue + "-nextArrowContinuesTimelineSeeking"] = model.playerTimelineFocused && model.playerScrub != nil
      model.cancelPlayerScrub()
      let pointer = model.beginPlayerScrub()
      model.updatePlayerScrub(20.5, ticket: pointer)
      checks[choice.rawValue + "-pointerCommitAccepted"] = pointer.map { model.commitPlayerScrub(ticket: $0) } == true
      await wait { abs(model.elapsed - 20.5) < 0.3 }
      let pointerSeek = await clock()
      checks[choice.rawValue + "-pointerCommitSeeksActualClock"] = abs(pointerSeek - 20.5) < 0.3 && model.paused
      let stale = model.beginPlayerScrub(); model.cancelPlayerScrub()
      let current = model.beginPlayerScrub(); model.updatePlayerScrub(15, ticket: current)
      checks[choice.rawValue + "-cancelledPointerTicketCannotCommitNewDraft"] = stale.map { !model.commitPlayerScrub(ticket: $0) } == true
        && model.playerScrub?.ticket == current && model.playerScrub?.position == 15
      if let current { _ = model.commitPlayerScrub(ticket: current) }
      await wait { abs(model.elapsed - 15) < 0.3 }
      observations[choice.rawValue] = ["initial": initial, "preview": preview, "afterPreview": afterPreview,
        "remoteTarget": target, "remoteClock": remoteSeek, "pointerClock": pointerSeek, "physicalRemoteOrTouchpadVerified": false]
      model.showPlayerControls(); model.handle(.up)
      let active = model.mpvEngine?.windowForTesting() ?? window
      capture(active, to: output.appendingPathComponent(choice.rawValue + "-timeline.png"))
      model.cancelPlayerScrub(); model.showPlayerControls()
      active.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); await settle()
      let pointerHost = hostingView(active.contentView)
      var pointerContext: [String: Any] = ["active": NSApp.isActive, "key": active.isKeyWindow, "visible": active.isVisible]
      pointerContext["hostFound"] = pointerHost != nil
      pointerContext["hostFlipped"] = pointerHost?.isFlipped ?? false
      pointerContext["hostBounds"] = pointerHost.map { NSStringFromRect($0.bounds) } ?? "missing"
      pointerContext["hostSafeAreaTop"] = pointerHost?.safeAreaInsets.top ?? -1
      pointerContext["frame"] = model.timelineFrameForTesting.map { NSStringFromRect($0) } ?? "missing"
      observations[choice.rawValue + "-pointerContext"] = pointerContext
      if let slider = nativeSlider(active.contentView), let host = hostingView(active.contentView), NSApp.isActive, active.isKeyWindow {
        let frame = host.convert(slider.bounds, from: slider)
        for (type, ratio) in [(NSEvent.EventType.leftMouseDown, 0.4), (.leftMouseDragged, 0.6), (.leftMouseUp, 0.6)] {
          let sliderPoint = NSPoint(x: slider.bounds.minX + slider.bounds.width * ratio, y: slider.bounds.midY)
          let localPoint = host.convert(sliderPoint, from: slider)
          let point = slider.convert(sliderPoint, to: nil)
          if type == .leftMouseDown {
            observations[choice.rawValue + "-hitTest"] = ["windowPoint": NSStringFromPoint(point),
              "hostPoint": NSStringFromPoint(localPoint), "view": active.contentView?.hitTest(point).map { String(describing: Swift.type(of: $0)) } ?? "none"]
          }
          if let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: active.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
            NSApp.postEvent(event, atStart: false)
            try? await Task.sleep(for: .milliseconds(100))
          }
        }
        await wait { model.elapsed > 24 && model.elapsed < 30 }
        let dragged = await clock()
        checks[choice.rawValue + "-nativeSliderDragSeeksBackend"] = dragged > 24 && dragged < 30 && model.playerScrub == nil
        observations[choice.rawValue + "-nativeDrag"] = ["clock": dragged, "frame": NSStringFromRect(frame), "physicalTouchpadVerified": false]
      } else {
        checks[choice.rawValue + "-inactiveOrUnlaidOutWindowDoesNotReceiveSyntheticMouseInput"] = true
        observations[choice.rawValue + "-nativeDrag"] = ["verified": false,
          "reason": "No active key window or live slider geometry; no mouse events posted", "physicalTouchpadVerified": false]
      }
      model.showPlayerControls(); model.handle(.up)
      let oldTicket = model.playerScrub?.ticket
      await stop()
      checks[choice.rawValue + "-stoppedVideoRejectsLatePointerCommit"] = oldTicket.map { !model.commitPlayerScrub(ticket: $0) } == true
        && model.playerScrub == nil && model.playerSeekPreview == nil
    }
    if let data = try? JSONSerialization.data(withJSONObject: observations, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("timeline-observations.json"))
    }
    return checks
  }
}

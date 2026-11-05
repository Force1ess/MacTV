import AppKit
import AVFoundation
import CoreAudio
import Foundation
import ImageIO
import MTVCore

@MainActor private final class BenchmarkFullscreenObservation {
  var entered = false
}

extension UISmoke {
  static func playbackBenchmarkRun(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    let args = CommandLine.arguments
    func argument(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    guard !args.contains("--audio-output-only"), !args.contains("--test-audible-output") else {
      return ["benchmarkAudibleHardwareScopeIsSeparate": false]
    }
    let fullscreen = args.contains("--benchmark-fullscreen")
    func visible(_ candidate: NSWindow) -> Bool {
      candidate.isVisible && candidate.isOnActiveSpace && candidate.occlusionState.contains(.visible) && candidate.alphaValue > 0.99
    }
    func fillsDisplay(_ candidate: NSWindow) -> Bool {
      guard let screen = candidate.screen else { return false }
      return abs(candidate.frame.width - screen.frame.width) < 4 && abs(candidate.frame.height - screen.frame.height) < 4
        && abs(candidate.frame.minX - screen.frame.minX) < 4 && abs(candidate.frame.minY - screen.frame.minY) < 4
    }
    guard let audioOutput = try? PlaybackBenchmarkAudioOutput.validated(arguments: args) else {
      return ["benchmarkAudioOutputArgumentValid": false]
    }
    let selectedAudio: AudioOutputDevice?
    do {
      selectedAudio = try AudioOutputHardware.resolve(audioOutput.rawValue)
      if audioOutput == .tv, selectedAudio?.hdmi != true { return ["benchmarkHDMIOutputAvailable": false] }
    } catch { return ["benchmarkAudioOutputAvailable": false] }
    let runtimeInfo = (try? Data(contentsOf: MPVPlaybackEngine.root.appendingPathComponent("SOURCE.json")))
      .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    let nativeFix = (runtimeInfo?["mpvLocalBuild"] as? [String: Any])?["upstreamFix"] as? String ?? "base-runtime"
    let pluginID = argument("--benchmark-plugin") ?? "mtv.bilibili"
    guard args.contains("--live-services"), let reference = argument("--benchmark-reference"),
      ["mtv.bilibili", "mtv.quark"].contains(pluginID),
      reference.range(of: pluginID == "mtv.bilibili" ? #"^BV[0-9A-Za-z]{10}(:[1-9][0-9]{0,15})?$"# : #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil,
      let plugin = model.plugins.first(where: { $0.id == pluginID }) else { return ["benchmarkRequiresExplicitLiveReference": false] }
    guard let requestedSession = try? PlaybackBenchmarkSession.validated(pluginID: pluginID, option: argument("--benchmark-session")) else {
      return ["benchmarkSessionArgumentValid": false]
    }
    if requestedSession == .stored, !PluginSessionStore().isConfigured(pluginID: pluginID) {
      return ["benchmarkStoredModeRequiresOwnValidatedLogin": false]
    }
    let sessionMode: PluginClient.SessionAccess = requestedSession == .stored ? .stored : .guest
    let containingFolder = argument("--benchmark-folder")
    if let containingFolder {
      guard pluginID == "mtv.quark", containingFolder.range(of: #"^[A-Za-z0-9_-]{1,128}$"#, options: .regularExpression) != nil else {
        return ["benchmarkContainingFolderValid": false]
      }
    }
    guard pluginID != "mtv.quark" || args.contains("--benchmark-original-file") || containingFolder != nil else {
      return ["benchmarkNormalQuarkPathRequiresRealFileCard": false]
    }
    let count = Int(argument("--benchmark-runs") ?? "5") ?? 5
    let variant = argument("--benchmark-variant") ?? "baseline"
    guard let observationSeconds = Double(argument("--benchmark-observe-seconds") ?? "3"),
      observationSeconds.isFinite, (3...300).contains(observationSeconds),
      Double(count)*observationSeconds<=1400 else { return ["benchmarkObservationArgumentValid": false] }
    guard !args.contains("--benchmark-no-initial-buffer") || args.contains("--benchmark-original-file") else {
      return ["benchmarkBufferExperimentRequiresOriginalFile": false]
    }
    guard !args.contains("--benchmark-head-first") || args.contains("--benchmark-original-file") else {
      return ["benchmarkHeadFirstRequiresOriginalFile":false]
    }
    guard !args.contains("--benchmark-original-file") || pluginID == "mtv.quark",
      !args.contains("--benchmark-direct-origin") || args.contains("--benchmark-original-file") else {
      return ["benchmarkOriginalAndDirectScopeValid":false]
    }
    guard !(args.contains("--benchmark-defer-playable") && args.contains("--benchmark-eager-playable")) else { return ["benchmarkPreparationControlIsUnambiguous": false] }
    guard (1...200).contains(count), variant.range(of: #"^[a-zA-Z0-9._-]{1,40}$"#, options: .regularExpression) != nil else { return ["benchmarkArgumentsValid": false] }
    if let bytes = argument("--benchmark-range-bytes") {
      guard ["65536", "131072", "262144", "1048576", "4194304", "10485760"].contains(bytes),
        !["4194304", "10485760"].contains(bytes) || args.contains("--benchmark-original-file") else {
        return ["benchmarkRangeParameterValid": false]
      }
    }
    if let depth = argument("--benchmark-range-depth"),
      !args.contains("--benchmark-original-file") || !["1", "2", "3", "4"].contains(depth) {
      return ["benchmarkRangeDepthParameterValid": false]
    }
    let presentationStarted = ProcessInfo.processInfo.systemUptime
    if fullscreen, !window.styleMask.contains(.fullScreen) {
      let state = BenchmarkFullscreenObservation()
      let observer = NotificationCenter.default.addObserver(forName: NSWindow.didEnterFullScreenNotification, object: window, queue: .main) { [weak state] _ in
        Task { @MainActor in state?.entered = true }
      }
      defer { NotificationCenter.default.removeObserver(observer) }
      window.toggleFullScreen(nil)
      let deadline = ProcessInfo.processInfo.systemUptime + 20
      while !state.entered && ProcessInfo.processInfo.systemUptime < deadline {
        try? await Task.sleep(for: .milliseconds(50))
      }
      guard state.entered else { return ["benchmarkFullscreenEnteredBeforeClick": false] }
    }
    let presentationDeadline = ProcessInfo.processInfo.systemUptime + 20
    while (!visible(window) || !window.isKeyWindow || !NSApp.isActive || (fullscreen && !fillsDisplay(window)))
      && ProcessInfo.processInfo.systemUptime < presentationDeadline {
      try? await Task.sleep(for: .milliseconds(50))
    }
    guard visible(window), window.isKeyWindow, NSApp.isActive, !fullscreen || fillsDisplay(window) else {
      return ["benchmarkPresentationReadyBeforeClick": false]
    }
    let presentationSetupMS = (ProcessInfo.processInfo.systemUptime - presentationStarted) * 1000
    let oldEngine = model.preferredEngine, oldSession = model.moduleSessionAccess
    defer { model.stopPlayback(); model.preferredEngine = oldEngine; model.moduleSessionAccess = oldSession; model.playbackBenchmark = nil; model.notice = nil; model.navigate(.home) }
    model.moduleSessionAccess = sessionMode; model.preferredEngine = .automatic
    model.openModule(plugin)
    for _ in 0..<300 { if !model.loading { break }; try? await Task.sleep(for: .milliseconds(50)) }
    var benchmarkItem = MediaItem(id:reference,title:"Playback benchmark",source:plugin.id,reference:reference)
    if pluginID == "mtv.bilibili" {
      // A video card includes its collection identity. Reuse the provider's
      // normal lookup contract instead of fabricating an incomplete card.
      let collection = String(reference.split(separator:":")[0])
      do {
        let data = try await PluginClient.execute(plugin,action:"lookup",input:["reference":collection],sessionAccess:sessionMode)
        let page = try JSONDecoder().decode(PluginPage.self,from:data)
        let cards = try PluginContentValidator.normalize(page.items,manifest:plugin.manifest)
        guard var card = cards.first(where: { $0.reference == collection && !$0.isFolder }),
          card.collectionReference == collection else { return ["benchmarkProviderCardAvailable":false] }
        card.reference = reference; card.id = reference; card.source = plugin.id
        benchmarkItem = card
      } catch { return ["benchmarkProviderCardAvailable":false] }
    } else if let containingFolder {
      do {
        var pageNumber = "1", visited = Set<String>(), selected: MediaItem?
        for _ in 0..<20 {
          guard visited.insert(pageNumber).inserted else { return ["benchmarkProviderPaginationValid":false] }
          let data = try await PluginClient.execute(plugin, action:"browse", input:["folder":containingFolder,"page":pageNumber], sessionAccess:sessionMode)
          let page = try JSONDecoder().decode(PluginPage.self, from:data)
          let cards = try PluginContentValidator.normalize(page.items, manifest:plugin.manifest)
          if let card = cards.first(where: { $0.reference == reference && !$0.isFolder }) { selected = card; break }
          guard let next = page.next else { break }
          guard next.range(of:#"^[0-9]{1,4}$"#,options:.regularExpression) != nil,
            let value=Int(next),(1...2000).contains(value) else { return ["benchmarkProviderPaginationValid":false] }
          pageNumber = next
        }
        guard let selected else { return ["benchmarkProviderCardAvailable":false] }
        benchmarkItem = selected
      } catch { return ["benchmarkProviderCardAvailable":false] }
    }
    var records: [PlaybackBenchmarkRecord] = []
    let file = output.appendingPathComponent("playback-benchmark.jsonl")
    do { try Data().write(to: file, options: .withoutOverwriting) }
    catch { return ["benchmarkRecordFileCreated": false] }
    for trial in 0..<count {
      let previousEngine = model.mpvEngine
      model.stopPlayback(); await previousEngine?.waitUntilStopped(); model.notice = nil
      let restoring = ProcessInfo.processInfo.systemUptime
      while (!visible(window) || !window.isKeyWindow || !NSApp.isActive || (fullscreen && !fillsDisplay(window)))
        && ProcessInfo.processInfo.systemUptime - restoring < 20 {
        try? await Task.sleep(for: .milliseconds(50))
      }
      guard visible(window), window.isKeyWindow, NSApp.isActive, !fullscreen || fillsDisplay(window) else {
        let failure: [String: Any] = ["phase":"browser-before-click", "trial":trial,
          "visible":visible(window), "keyWindow":window.isKeyWindow, "active":NSApp.isActive]
        if let data = try? JSONSerialization.data(withJSONObject: failure, options: [.prettyPrinted, .sortedKeys]) {
          try? data.write(to: output.appendingPathComponent("presentation-setup-failure.json"))
        }
        return ["benchmarkBrowserPresentationRestored": false]
      }
      let browserReadyMS = (ProcessInfo.processInfo.systemUptime - restoring) * 1000
      model.startPlaybackBenchmark(reference: reference, variant: variant, trial: trial)
      model.play(benchmarkItem,fromBeginning:true,sessionAccessOverride:sessionMode)
      let deadline = ProcessInfo.processInfo.systemUptime + 40
      var hasFrame = false
      var playbackFailed = false
      while ProcessInfo.processInfo.systemUptime < deadline {
        if model.player != nil, model.smokeDecodedPixelsAvailable() { model.markPlaybackBenchmark("pixelBufferAvailable") }
        if model.notice != nil || model.playbackInterruption != nil || model.player?.currentItem?.status == .failed {
          playbackFailed = true; break
        }
        if let engine = model.mpvEngine, let value = engine.latest, value.width > 0, value.height > 0,
          let videoWindow = engine.windowForTesting(), visible(videoWindow), !fullscreen || fillsDisplay(videoWindow),
          !value.seeking, !value.buffering, value.frames > 0 {
          let capture = output.appendingPathComponent(".benchmark-frame-"+UUID().uuidString+".png")
          defer { try? FileManager.default.removeItem(at:capture) }
          if (try? await engine.benchmarkVideoFrame(capture)) != nil,
            let source = CGImageSourceCreateWithURL(capture as CFURL,nil), let image = CGImageSourceCreateImageAtIndex(source,0,nil),
            image.width == value.width, image.height == value.height {
            model.markPlaybackBenchmark("renderReady"); hasFrame = true; break
          }
        }
        if model.player != nil, visible(window), (!fullscreen || fillsDisplay(window)),
          model.playbackBenchmark?.milestonesMS["displayReady"] != nil,
          let frame = model.testDecodedFrame(), frame.width > 0, frame.height > 0 {
          model.playbackBenchmark?.metadata["actualVideoDimensions"] = "\(frame.width)x\(frame.height)"
          model.markPlaybackBenchmark("renderReady")
          hasFrame = true; break
        }
        try? await Task.sleep(for: .milliseconds(25))
      }
      if hasFrame {
        func position() -> Double {
          let value=model.player?.currentTime().seconds ?? model.mpvEngine?.latest?.elapsed ?? model.elapsed
          return value.isFinite ? value:0
        }
        let observationStarted=ProcessInfo.processInfo.systemUptime, startPosition=position()
        let end=observationStarted+observationSeconds
        var lastPosition=startPosition, lastProgress=observationStarted, longestNoProgress=0.0
        while ProcessInfo.processInfo.systemUptime < end {
          if model.notice != nil || model.playbackInterruption != nil || (model.player == nil && model.mpvEngine == nil) || model.player?.currentItem?.status == .failed {
            playbackFailed = true; break
          }
          let now=ProcessInfo.processInfo.systemUptime, current=position()
          if current-lastPosition>0.15 { lastProgress=now; lastPosition=current }
          longestNoProgress=max(longestNoProgress,now-lastProgress)
          try? await Task.sleep(for: .milliseconds(50))
        }
        model.playbackBenchmark?.metadata["observedStartPosition"]=String(startPosition)
        model.playbackBenchmark?.metadata["observedEndPosition"]=String(position())
        model.playbackBenchmark?.metadata["observationWallSeconds"]=String(ProcessInfo.processInfo.systemUptime-observationStarted)
        model.playbackBenchmark?.metadata["longestObservedClockGapSeconds"]=String(longestNoProgress)
      }
      model.playbackBenchmark?.finish(reachedDecodedFrame: hasFrame, playbackFailed: playbackFailed)
      if var record = model.playbackBenchmark {
        if let media=model.originalRemoteMedia {
          record.metadata["rangeConnectionLifetime"]="app-shared-ephemeral"
          record.metadata["rangeChunkBytes"]=String(media.transfer.chunkBytes)
          record.metadata["rangePipelineDepth"]=String(media.transfer.depth)
          record.metadata["initialRangeDepth"]=String(media.transfer.initialDepth)
          record.metadata["originConnection"]=media.transfer.useSystemProxy ? "system-proxy":"request-direct-experiment"
          let trace=await media.benchmarkTrace()
          if let data=try? JSONSerialization.data(withJSONObject:trace,options:[.sortedKeys]) {
            try? data.write(to:output.appendingPathComponent("range-trace-\(trial).json"),options:.withoutOverwriting)
          }
        }
        if let engine=model.mpvEngine {
          record.metadata["nativeStartupTimeline"]=await engine.startupTimeline()
          for property in ["cache-pause-initial","cache-pause-wait","demuxer-mkv-probe-video-duration","demuxer-mkv-probe-start-time","demuxer-cache-duration","hwdec-current","duration","file-size","file-format","current-ao","audio-codec-name","audio-pts","audio-out-params","aid","mute"] {
            record.metadata["player."+property]=await engine.diagnostic(property)
          }
          record.metadata["audioPlaybackMuted"] = String(record.metadata["player.mute"] == "yes")
        } else if let player = model.player {
          record.metadata["audioPlaybackMuted"] = String(player.isMuted)
        }
        record.metadata["audioOutputRequested"] = audioOutput.rawValue
        record.metadata["presentationRequested"] = fullscreen ? "full-screen" : "windowed"
        record.metadata["presentationSetupBeforeClicksMS"] = String(presentationSetupMS)
        record.metadata["browserReadyBeforeClickMS"] = String(browserReadyMS)
        let videoWindow = model.mpvEngine?.windowForTesting() ?? window
        record.metadata["windowVisibleOnActiveSpace"] = String(visible(videoWindow))
        record.metadata["windowIsKey"] = String(videoWindow.isKeyWindow)
        record.metadata["presentationScopeVerified"] = String(visible(videoWindow) && (!fullscreen || fillsDisplay(videoWindow)))
        record.metadata["windowSizePoints"] = "\(Int(videoWindow.frame.width))x\(Int(videoWindow.frame.height))"
        record.metadata["displayBackingScale"] = String(Double(videoWindow.backingScaleFactor))
        record.metadata["nativeRuntimeUpstreamFix"] = nativeFix
        if let selectedAudio {
          let running = AudioOutputHardware.uint(selectedAudio.id, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
          record.metadata["selectedHDMIDeviceRunning"] = String(running)
          if model.mpvEngine != nil {
            let ownOutput = AudioOutputHardware.processUsesOutput(selectedAudio.id, pid: UInt32(ProcessInfo.processInfo.processIdentifier))
            record.metadata["ownProcessUsesSelectedAudioOutput"] = ownOutput.map(String.init) ?? "unavailable"
            record.metadata["audioOutputScopeVerified"] = String(record.metadata["player.current-ao"] == "coreaudio"
              && ownOutput == true && !(record.metadata["player.audio-codec-name"] ?? "").isEmpty
              && (Double(record.metadata["player.audio-pts"] ?? "") ?? 0) > 0)
          } else if let player = model.player {
            let tracks = try? await player.currentItem?.asset.loadTracks(withMediaType: .audio)
            record.metadata["system.requestedAudioDeviceMatches"] = String(player.audioOutputDeviceUniqueID == selectedAudio.uid)
            record.metadata["system.assetAudioTrackCount"] = String(tracks?.count ?? -1)
            record.metadata["system.enabledItemTrackCount"] = String(player.currentItem?.tracks.filter(\.isEnabled).count ?? 0)
            let ownOutput = AudioOutputHardware.processUsesOutput(selectedAudio.id, pid: UInt32(ProcessInfo.processInfo.processIdentifier))
            record.metadata["ownProcessUsesSelectedAudioOutput"] = ownOutput.map { $0 ? "true" : "false" } ?? "unavailable"
            let localAudioSelected = !(tracks ?? []).isEmpty && player.currentItem?.tracks.contains {
              $0.isEnabled && $0.assetTrack?.mediaType == .audio
            } == true
            var streamingAudioSelected = false
            if let item = player.currentItem,
              let group = try? await item.asset.loadMediaSelectionGroup(for: .audible) {
              record.metadata["system.audibleOptionCount"] = String(group.options.count)
              let selected = item.currentMediaSelection.selectedMediaOption(in: group)
              record.metadata["system.audibleOptionSelected"] = String(selected != nil)
              streamingAudioSelected = selected?.mediaType == .audio && selected?.isPlayable == true
            }
            record.metadata["system.selectedAudioRepresentation"] = streamingAudioSelected ? "media-selection-group" : localAudioSelected ? "asset-track" : "unverified"
            record.metadata["audioOutputScopeVerified"] = String(player.audioOutputDeviceUniqueID == selectedAudio.uid
              && running && ownOutput == true && (localAudioSelected || streamingAudioSelected))
          } else { record.metadata["audioOutputScopeVerified"] = "false" }
        } else { record.metadata["audioOutputScopeVerified"] = "system-default-not-asserted" }
        let statistics = await model.smokeRemoteStatistics()
        for (key, value) in statistics { record.metadata["stream." + key] = String(value) }
        record.metadata["prefixCache"] = args.contains("--benchmark-prefix-cache") ? "enabled" : "disabled"
        record.metadata["session"] = requestedSession.rawValue
        record.metadata["plugin"] = pluginID
        record.metadata["startupBudgetPolicy"] = pluginID == "mtv.quark" ? PlaybackBenchmarkRecord.quarkSevenSecondPolicy : "decoded-dimensions-v1"
        record.metadata["sourceRevision"] = Bundle.main.object(forInfoDictionaryKey:"MacTVSourceRevision") as? String ?? "unversioned"
        record.metadata["observer"] = model.mpvEngine != nil ? "libmpv.screenshot.video;visibleActiveSpaceWindow;CGImage.matchesNativeDimensions;captureCostIncluded" : "AVPlayerView.displayReady;visibleActiveSpaceWindow;CGImage.validated;captureCostIncluded"
        record.metadata["playingObserver"] = model.mpvEngine != nil ? "libmpv.observed.pause;time-pos;paused-for-cache" : "AVPlayer.timeControlStatus.KVO"
        if let value = model.mpvEngine?.latest { record.metadata["actualVideoDimensions"] = "\(value.width)x\(value.height)" }
        if model.duration.isFinite, model.duration > 0 { record.metadata["durationSeconds"] = String(model.duration) }
        record.metadata["sourceTransport"] = model.originalRemoteMedia != nil ? "original-matroska" : model.player != nil ? "provider-stream" : "not-active"
        record.metadata["originalTransportExplicitlyRequested"] = String(args.contains("--benchmark-original-file"))
        let fileExtension = URL(fileURLWithPath:benchmarkItem.title).pathExtension.lowercased()
        if fileExtension.range(of:#"^[a-z0-9]{1,8}$"#,options:.regularExpression) != nil { record.metadata["sourceFileExtension"] = fileExtension }
        record.metadata["rebufferObservationSeconds"] = String(observationSeconds)
        record.metadata["initialBuffer"] = args.contains("--benchmark-no-initial-buffer") ? "disabled-experiment":"player-default"
        record.metadata["itemSource"] = pluginID == "mtv.bilibili" ? "provider-lookup" : containingFolder != nil ? "provider-folder-card" : "explicit-original-file-reference"
        record.metadata["completionPolicy"] = "decodedFrameAndPlayingNoObservedFailure"
        record.metadata["adapter"] = model.smokePlaybackResolution["adapter"] as? String ?? "unknown"
        record.metadata["quality"] = String(model.smokePlaybackResolution["qualityCode"] as? Int ?? -1)
        if record.metadata["rangeChunkBytes"] == nil { record.metadata["rangeChunkBytes"] = argument("--benchmark-range-bytes") ?? "1048576" }
        if record.metadata["originConnection"] == nil { record.metadata["originConnection"] = "system-proxy" }
        record.metadata["nativeLogStages"] = args.contains("--benchmark-log-stages") ? "on":"off"
        if record.metadata["playablePreparation"] == nil { record.metadata["playablePreparation"] = "not-prepared" }
        records.append(record)
        do {
          let data = try JSONEncoder().encode(record), handle = try FileHandle(forWritingTo: file)
          defer { try? handle.close() }
          try handle.seekToEnd(); try handle.write(contentsOf: data + Data([10]))
        } catch { model.stopPlayback(); return ["benchmarkRecordPersisted": false] }
      }
      model.stopPlayback()
    }
    let summary = PlaybackBenchmarkRecord.summary(records)
    if let data = try? JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("playback-benchmark-summary.json"))
    }
    return ["benchmarkRecordedAllTrials": records.count == count,
      "benchmarkAllTrialsReachedActualFrame": records.count == count && records.allSatisfy { $0.outcome == "ready" },
      "benchmarkRequestedHDMIOutputVerified": audioOutput != .tv || (records.count == count && records.allSatisfy { $0.metadata["audioOutputScopeVerified"] == "true" }),
      "benchmarkPlaybackRemainsMuted": records.count == count && records.allSatisfy { $0.metadata["audioPlaybackMuted"] == "true" },
      "benchmarkRequestedPresentationVerified": records.count == count && records.allSatisfy { $0.metadata["presentationScopeVerified"] == "true" },
      "benchmarkNoAudioTapAttached": true]
  }
}

import AppKit
import AVFoundation
import Foundation
import MTVCore

/// Structured observations and commands over the same model the SwiftUI uses.
/// It is enabled only by an explicit launch option, never by a plugin or URL.
@MainActor final class AppControl {
  private weak var model: AppModel?
  private let server = LocalControlServer()
  private var observation: Task<Void, Never>?
  private let files = DispatchQueue(label: "local.mtv.control.journal")
  private var events: [[String: Any]] = []
  private var sequence = 0
  private let runID = UUID().uuidString
  private var previous = Data()
  private var enabled = false
  private var journalFailed = false
  private let allowAccountImport: Bool
  private var pluginReviews: [UUID:PluginInstallReview] = [:]
  private var pluginReviewSources: [UUID:PluginSource] = [:]
  private var pluginMutationActive = false
  private var allowPluginManagement: Bool { CommandLine.arguments.contains("--allow-plugin-management") }
  private var allowAccountInteraction: Bool {
    allowAccountImport && CommandLine.arguments.contains("--allow-account-interaction")
  }
  init(model: AppModel, allowAccountImport: Bool) {
    self.model = model; self.allowAccountImport = allowAccountImport
  }
  func start() throws {
    try server.start { [weak self] request in
      guard let self else { return LocalControlJSON.failure("control-stopped", id: request.id) }
      return await self.receive(request)
    }
    enabled = true
    record("control.started", fields: ["accountImportEnabled": allowAccountImport])
    observe()
    observation = Task { [weak self] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        self?.observe()
      }
    }
  }
  func stop() {
    guard enabled else { return }
    record("control.stopping", fields: [:])
    enabled = false; observation?.cancel(); observation = nil; server.stop()
    let reviews = Array(pluginReviews.keys); pluginReviews.removeAll(); pluginReviewSources.removeAll()
    Task { for id in reviews { await PluginClient.packages.cancel(id) } }
    write(snapshot())
  }
  private func record(_ type: String, fields: [String: Any]) {
    sequence += 1
    events.append(["sequence": sequence, "runID": runID, "pid": ProcessInfo.processInfo.processIdentifier,
      "at": Date().timeIntervalSince1970, "type": type, "fields": fields])
    if events.count > 512 { events.removeFirst(events.count - 512) }
    let data = events.reduce(into: Data()) { $0.append(LocalControlJSON.encode($1)); $0.append(10) }
    files.async { [weak self] in
      do { try LocalControlPaths.write(data, name: "events.jsonl", root: LocalControlPaths.root) }
      catch { Task { @MainActor in self?.journalFailed = true } }
    }
  }
  private func write(_ value: [String: Any]) {
    let data = LocalControlJSON.encode(value)
    files.async { [weak self] in
      do { try LocalControlPaths.write(data, name: "state.json", root: LocalControlPaths.root) }
      catch { Task { @MainActor in self?.journalFailed = true } }
    }
  }
  private func observe() {
    guard enabled else { return }
    let value = snapshot()
    // Clock progress is available in status/state.json but is not a log event.
    var signature = value
    signature.removeValue(forKey: "updatedAt"); signature.removeValue(forKey: "eventSequence")
    signature.removeValue(forKey: "mediaLayout")
    if var playback = signature["playback"] as? [String: Any] {
      playback.removeValue(forKey: "elapsed"); playback.removeValue(forKey: "duration")
      playback.removeValue(forKey: "nativeElapsed"); playback.removeValue(forKey: "nativeDuration")
      signature["playback"] = playback
    }
    let encoded = LocalControlJSON.encode(signature)
    if previous != encoded {
      previous = encoded
      var summary = signature
      for key in ["navigation", "accounts", "window", "input"] { summary.removeValue(forKey: key) }
      if let login = summary["login"] as? [String: Any] {
        summary["login"] = login.filter { ["presented", "state", "plugin", "chromeProfilesUnavailable", "platformVerifiedThisRun", "chromeImportDiagnostic"].contains($0.key) }
      }
      if let playback = summary["playback"] as? [String: Any] {
        summary["playback"] = playback.filter { !["item", "availableRates", "qualities"].contains($0.key) }
      }
      if let notice = summary["notice"] as? String { summary["notice"] = String(notice.prefix(256)) }
      record("state.changed", fields: summary)
    }
    write(snapshot())
  }
  private func text(_ value: String) -> String { LocalControlJSON.safeText(value) }
  private func number(_ value: Double) -> Double { value.isFinite ? value : 0 }
  private func item(_ value: MediaItem) -> [String: Any] {
    let safeID = text(value.id)
    var result: [String: Any] = ["id": safeID, "addressable": safeID == value.id,
      "title": text(String(value.title.prefix(256))), "titleTruncated": value.title.count > 256,
      "subtitle": text(String(value.subtitle.prefix(160))), "overview": text(String(value.overview.prefix(256))),
      "overviewTruncated": value.overview.count > 256,
      "kind": value.kind?.rawValue ?? "video",
      "source": value.source, "hasPoster": value.poster != nil]
    // Only the native model keeps resolved media/artwork URLs and credentials.
    if let reference = value.reference, !reference.contains("://"), text(reference) == reference { result["reference"] = reference }
    return result
  }
  private func snapshot() -> [String: Any] {
    guard let model else { return ["schema": 1, "phase": "stopped"] }
    var overlays: [String] = []
    for (shown, name) in [(model.notice != nil, "notice"), (model.login.isPresented, "login"),
      (model.mediaSessionConsent != nil, "mediaSessionConsent"),
      (model.keyboardVisible, "keyboard"), (model.metadata.isPresented, "metadata"),
      (model.automaticMetadata.isPresented, "recognition"), (model.appearanceVisible, "appearance"),
      (model.navigationCustomizationVisible, "navigation"), (model.audioOutputVisible, "audioOutput"),
      (model.savedSources.isPresented, "sources"),
      (model.localFolders.isPresented, "localFolders"), (model.smb.isPresented, "smb"),
      (model.sourceSetup.isPresented, "sourceSetup"), (model.pluginManager.isPresented, "pluginManager"),
      (model.information.isPresented, "information"), (model.setupGuideVisible, "setupGuide"), (model.nativeMedia.isPresented, "nativeMedia"),
      (model.playbackTracks.isPresented, "tracks"), (model.playbackSpeedVisible, "speed"),
      (model.playbackQualityVisible, "quality"), (model.playbackVolumeVisible, "volume")] {
      if shown { overlays.append(name) }
    }
    var login: [String: Any] = ["presented": model.login.isPresented, "state": model.login.state, "message": text(model.login.message), "displayMessage": text(model.login.displayedMessage),
      "buttons": model.login.isPresented ? model.login.buttons.map(text) : [],
      "buttonDisplayTitles": model.login.isPresented ? model.login.displayedButtonTitles.map(text) : [], "selection": model.login.selectedButton,
      "chromeProfilesUnavailable": model.login.chromeProfilesUnavailable,
      "chromeProfiles": model.login.availableChromeProfileTitles.map(text),
      "chromeImportDiagnostic": model.login.chromeImportDiagnostic,
      "platformVerifiedThisRun": model.login.platformVerificationIsReal]
    if let plugin = model.login.plugin { login["plugin"] = plugin.id }
    var playback: [String: Any] = ["presented": model.playbackPresented, "preparing": model.preparingPlayback,
      "paused": model.paused, "elapsed": number(model.elapsed), "duration": number(model.duration),
      "volume": model.playbackVolume,
      "effectiveVolume": model.effectivePlaybackVolume,
      "systemVolumeScale": model.systemPlaybackGain,
      "rate": model.playbackRate, "controlsVisible": model.playerControlsVisible, "timelineFocused": model.playerTimelineFocused,
      "cursorHideRequested": TVPointerFocus.cursorHideRequested,
      "availableRates": model.playbackRates,
      "engine": model.mpvEngine != nil ? "mpv" : model.vlcEngine != nil ? "vlc" : model.player != nil ? "system" : "none"]
    if let playing = model.playingItem { playback["item"] = item(playing) }
    if let quality = model.bilibiliActualQuality { playback["quality"] = quality }
    playback["qualities"] = model.bilibiliQualityOptions.map { ["id": $0.id, "title": text($0.title), "available": $0.available] as [String: Any] }
    if let native = model.mpvEngine?.latest {
      playback["nativeFrameEstimate"] = native.frames; playback["nativeVideoOutput"] = native.vo; playback["colorMatrix"] = native.matrix
      playback["nativeSeeking"] = native.seeking; playback["nativeBuffering"] = native.buffering
      playback["nativeElapsed"] = number(native.elapsed); playback["nativeDuration"] = number(native.duration)
      playback["nativePaused"] = native.paused
      playback["videoWidth"] = native.width; playback["videoHeight"] = native.height
    }
    let tracks = model.playbackTracks
    playback["tracks"] = ["presented": tracks.isPresented, "requestID": tracks.requestID,
      "kind": tracks.kind == .audio ? "audio" : "subtitles", "loading": tracks.loading, "busy": tracks.busy,
      "selectedID": tracks.selectedID, "selection": tracks.selection, "message": text(tracks.message),
      "options": tracks.options.enumerated().map { index, option -> [String: Any] in
        var result: [String: Any] = ["index": index, "title": text(String(option.title.prefix(256))), "external": option.subtitle != nil,
          "selected": tracks.isSelected(option)]
        if let id = option.trackID { result["trackID"] = id }
        return result
      }]
    if let player = model.player {
      playback["timeControlStatus"] = player.timeControlStatus.rawValue; playback["itemStatus"] = player.currentItem?.status.rawValue ?? 0
      playback["nativeElapsed"] = number(player.currentTime().seconds)
      playback["nativeRate"] = player.rate
      playback["nativeDuration"] = number(player.currentItem?.duration.seconds ?? 0)
      playback["videoWidth"] = Double(player.currentItem?.presentationSize.width ?? 0)
      playback["videoHeight"] = Double(player.currentItem?.presentationSize.height ?? 0)
    }
    let configured = model.plugins.filter { $0.manifest.authentication != nil }.map { plugin in
      ["plugin": plugin.id, "configured": PluginSessionStore().isConfigured(pluginID: plugin.id)] as [String: Any]
    }
    var value: [String: Any] = ["schema": 1, "pid": ProcessInfo.processInfo.processIdentifier, "controlRunID": runID,
      "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
      "phase": enabled ? "running" : "stopped", "updatedAt": Date().timeIntervalSince1970,
      "sourceRevision":Bundle.main.object(forInfoDictionaryKey:"MacTVSourceRevision") as? String ?? "unversioned",
      "inputIdleSeconds":RuntimeTestGuard.idleSeconds(),
      "eventSequence": sequence, "journalWriteFailed": journalFailed, "active": NSApp.isActive,
      "approvedQuarkMediaSessionEnabled": model.hasMediaSessionApproval(pluginID: "mtv.quark", host: FirstPartyMediaScope.quarkHost),
      "approvedQuarkMediaSessionHosts": FirstPartyMediaScope.quarkHosts.filter { model.hasMediaSessionApproval(pluginID: "mtv.quark", host: $0) }.sorted(),
      "visualExportEnabled": CommandLine.arguments.contains("--enable-visual-export"),
      "keyWindow": NSApp.keyWindow?.identifier?.rawValue == "MTVMainWindow",
      "section": String(describing: model.section), "focus": ["row": model.focus.row, "column": model.focus.column],
      "navigation": model.visibleNavigationTabs.map { ["id": $0.rawValue, "title": $0.title, "selected": $0 == model.activeNavigationTab] as [String: Any] },
      "settings": ["categories": TVSetting.groupTitles.map { LT($0) }, "group": model.settingsGroup, "sidebarFocused": model.settingsSidebarFocus,
        "appearance": model.appearance.title],
      "overlays": overlays, "accountImportEnabled": allowAccountImport, "pluginManagementEnabled":allowPluginManagement,
      "pluginManager":model.pluginManager.diagnostics,
      "documentationPreview": CommandLine.arguments.contains("--ui-smoke") && CommandLine.arguments.contains("--documentation-preview"),
      "volatileHistory": CommandLine.arguments.contains("--ui-smoke") || CommandLine.arguments.contains("--qa-volatile-history"),
      "accountInteractionEnabled": allowAccountInteraction,
      "library": ["refreshing": model.libraryRefreshing, "files": model.libraryFilesForMaintenance.count,
        "rootCards": model.libraryCatalog.root.count, "depth": model.libraryPath.count,
        "status": text(model.libraryStatus)],
      "module": ["id": model.activePlugin?.id ?? "", "loading": model.loading, "items": model.online.count,
        "hasNext": model.moduleNextPage != nil, "needsLogin": model.moduleNeedsLogin, "failed": model.moduleLoadFailure != nil],
      "login": login, "accounts": configured, "playback": playback,
      "nativeMedia": ["presented":model.nativeMedia.isPresented, "kind":model.nativeMedia.item?.kind?.rawValue ?? "",
        "imageFailure":model.nativeMedia.imageFailure,
        "id":model.nativeMedia.item?.id ?? "", "imageWidth":model.nativeMedia.image?.size.width ?? 0,
        "imageHeight":model.nativeMedia.image?.size.height ?? 0, "elapsed":number(model.nativeMedia.elapsed),
        "duration":number(model.nativeMedia.duration), "volume":model.nativeMedia.volume, "artworkWidth":model.nativeMedia.audioArtwork?.size.width ?? 0, "audioState":model.nativeMedia.audioState, "paused":model.nativeMedia.paused, "message":text(model.nativeMedia.message)],

      "input": ["visible": model.keyboardVisible, "secret": model.keyboardSecret,
        "target": String(describing: model.textEntryTarget), "textLength": model.keyboardSecret ? 0 : model.inputText.utf8.count,
        "dictationReadiness": model.systemDictationReadiness, "lastDictationRequest": model.lastDictationRequest]]
    if let notice = model.notice { value["notice"] = text(notice) }
    if let layout = model.mediaFocusLayout, layout.itemID == model.focusedMediaItem?.id,
      layout.row == model.focus.row, layout.column == model.focus.column {
      value["mediaLayout"] = ["itemID": text(layout.itemID), "row": layout.row, "column": layout.column,
        "coordinateSpace": "content-viewport-points", "titleFullyVisible": layout.titleFullyVisible,
        "title": ["x": number(layout.title.minX), "y": number(layout.title.minY),
          "width": number(layout.title.width), "height": number(layout.title.height)],
        "viewport": ["width": number(layout.viewport.width), "height": number(layout.viewport.height)]]
    }
    if let pending = model.mediaSessionConsent {
      value["mediaSessionConsent"] = ["plugin": pending.pluginID, "host": pending.host,
        "selection": model.mediaSessionConsentSelection, "buttons": [L("Allow and Open"), L("Not Now")], "actionIDs":["approve","cancel"]]
    }
    if model.information.isPresented {
      value["information"] = ["page": model.information.page.rawValue, "selection": model.information.selection,
        "noticeCount": model.information.notices.count, "documentLength": model.information.document.count,
        "hasTMDBLogo": model.information.logo != nil]
    }
    if model.setupGuideVisible {
      var guide: [String: Any] = ["step": model.setupGuideStep, "title": model.guideTitle,
        "description": model.guideDescription, "selection": model.setupGuideSelection,
        "nextIndex": model.guideActions.count + 1, "skipIndex": model.guideActions.count + 2,
        "actions": model.guideActions.enumerated().map { ["index": $0.offset, "title": LT($0.element.0), "description": LT($0.element.1)] as [String: Any] }]
      if model.setupGuideStep == 3 {
        guide["keymap"] = TVKeyBindings.guide.map { ["action": LT($0.action), "keys": LT($0.keys)] }
        if let devices = model.guideInputDevices, let data = try? JSONEncoder().encode(devices), let object = try? JSONSerialization.jsonObject(with: data) { guide["inputDevices"] = object }
      }
      value["guide"] = guide
    }
    if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "MTVMainWindow" }) {
      value["window"] = ["visible": window.isVisible, "fullscreen": window.styleMask.contains(.fullScreen),
        "width": Double(window.contentLayoutRect.width), "height": Double(window.contentLayoutRect.height),
        "hasAttachedSheet": window.attachedSheet != nil]
    }
    if let scan = model.libraryScanObservation, let data = try? JSONEncoder().encode(scan),
      var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
      object["root"] = text(scan.root)
      value["libraryScan"] = object
    }
    return value
  }
  private func receive(_ request: LocalControlRequest) async -> Data {
    guard enabled, let model, !Task.isCancelled else { return LocalControlJSON.failure("control-stopped", id: request.id) }
    do { try request.validate() } catch { return LocalControlJSON.failure("expired-request", id: request.id) }
    let args = request.arguments
    func failure(_ code: String) -> Data {
      record("command.rejected", fields: ["id": request.id.uuidString, "command": request.command, "code": code])
      return LocalControlJSON.failure(code, id: request.id)
    }
    func arguments(_ allowed: [String]) -> Bool { Set(args.keys).isSubset(of: Set(allowed)) }
    var result: [String: Any] = [:]
    var accepted = false
    switch request.command {
    case "status":
      guard args.isEmpty else { return failure("invalid-arguments") }
    case "window.show":
      guard args.isEmpty, let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "MTVMainWindow" }) else { return failure("window-not-available") }
      window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); accepted = true
    case "window.list":
      guard args.isEmpty, !model.keyboardSecret else { return failure("window-state-unavailable") }
      result["windows"] = NSApp.windows.map { ["title": text($0.title), "identifier": $0.identifier?.rawValue ?? "", "class": String(describing: type(of: $0)), "visible": $0.isVisible, "key": $0.isKeyWindow] as [String: Any] }
    case "visual.viewport":
      guard CommandLine.arguments.contains("--enable-visual-export") else { return failure("visual-export-not-enabled") }
      guard arguments(["width", "height"]), let width = args["width"].flatMap(Double.init), let height = args["height"].flatMap(Double.init),
        width.isFinite, height.isFinite, (1100...3840).contains(width), (700...2160).contains(height),
        let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "MTVMainWindow" }),
        !window.styleMask.contains(.fullScreen) else { return failure("visual-viewport-not-available") }
      window.setContentSize(NSSize(width: width, height: height)); accepted = true
    case "visual.export":
      guard CommandLine.arguments.contains("--enable-visual-export") else { return failure("visual-export-not-enabled") }
      guard arguments(["purpose"]), let purpose = args["purpose"], ["layout", "animation", "playback", "subtitles"].contains(purpose) else { return failure("invalid-visual-purpose") }
      if ["playback", "subtitles"].contains(purpose), let engine = model.mpvEngine,
        !model.login.isPresented, !model.keyboardVisible, !model.smb.isPresented {
        do {
          let root = LocalControlPaths.root.deletingLastPathComponent().appendingPathComponent("VisualExports")
          try LocalControlPaths.prepare(root)
          let temporary = root.appendingPathComponent(".frame-" + UUID().uuidString + ".png")
          defer { try? FileManager.default.removeItem(at: temporary) }
          try await engine.screenshot(temporary)
          guard model.mpvEngine === engine else { return failure("playback-changed") }
          let file = try LocalControlPaths.writeVisual(Data(contentsOf: temporary), root: root)
          result = ["file": file.path, "purpose": purpose, "scope": "native-player-frame-only"]
          break
        } catch { return failure("native-frame-export-failed") }
      }
      guard !model.login.isPresented, !model.keyboardVisible, !model.smb.isPresented,
        let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "MTVMainWindow" }),
        let view = window.contentView else { return failure("visual-export-unavailable-or-sensitive") }
      view.layoutSubtreeIfNeeded()
      guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return failure("visual-export-unavailable-or-sensitive") }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      guard let data = bitmap.representation(using: .png, properties: [:]) else { return failure("visual-export-failed") }
      do {
        let root = LocalControlPaths.root.deletingLastPathComponent().appendingPathComponent("VisualExports")
        let file = try LocalControlPaths.writeVisual(data, root: root)
        result = ["file": file.path, "purpose": purpose, "width": bitmap.pixelsWide, "height": bitmap.pixelsHigh, "scope": "MTV-content-view-only"]
        record("visual.exported", fields: ["purpose": purpose])
      } catch { return failure("visual-export-write-failed") }
    case "events":
      guard arguments(["after"]), let after = Int(args["after"] ?? "0"), after >= 0 else { return failure("invalid-arguments") }
      let available = events.filter { ($0["sequence"] as? Int ?? 0) > after }
      let page = Array(available.prefix(64))
      result["events"] = page
      result["nextAfter"] = page.last?["sequence"] ?? after
      result["hasMore"] = available.count > page.count
      result["oldestAvailable"] = events.first?["sequence"] ?? 0
    case "navigate":
      let sections: [String: Section] = ["home": .home, "library": .library, "bilibili": .bilibili, "apps": .extensions, "settings": .settings]
      guard arguments(["section"]), let target = args["section"].flatMap({ sections[$0] }) else { return failure("invalid-section") }
      model.navigate(target); accepted = true
    case "input.key":
      guard arguments(["key"]), let key = args["key"] else { return failure("invalid-key") }
      model.login.controlRejection = nil
      let keys: [String: InputAction] = ["up": .up, "down": .down, "left": .left, "right": .right,
        "select": .select, "back": .back, "menu": .menu, "home": .home]
      if key == "escape" || key == "backspace" {
        model.handle(TVKeyBindings.navigationAction(keyCode: key == "escape" ? 53 : 51, keyboardVisible: model.keyboardVisible)!,
          chromeImportAllowed: allowAccountImport, interactiveLoginAllowed: allowAccountInteraction)
      } else if let action = keys[key] { model.handle(action, chromeImportAllowed: allowAccountImport, interactiveLoginAllowed: allowAccountInteraction) }
      else { return failure("invalid-key") }
      if let rejection = model.login.controlRejection { return failure(rejection) }
      accepted = true
    case "input.text":
      guard arguments(["text"]), let value = args["text"], model.keyboardVisible, !model.keyboardSecret else { return failure("nonsecret-input-not-open") }
      model.acceptSystemText(value); accepted = true
    case "input.submit":
      guard args.isEmpty, model.keyboardVisible, !model.keyboardSecret else { return failure("nonsecret-input-not-open") }
      model.finishTextEntry(commit:true); accepted=true
    case "input.open":
      guard args.isEmpty, !model.playbackPresented, !model.login.isPresented else { return failure("input-not-available") }
      model.showKeyboard(); accepted = true
    case "account.chromeAccess":
      guard args.isEmpty else { return failure("invalid-arguments") }
      let access = await Task.detached(priority: .utility) { ChromeStorageAccess.inspect() }.value
      do {
        try request.validate()
        result = (try JSONSerialization.jsonObject(with: JSONEncoder().encode(access))) as? [String: Any] ?? [:]
      } catch { return failure("chrome-access-observation-failed-or-expired") }
    case "application.status":
      guard args.isEmpty else { return failure("invalid-arguments") }
      result = ["phase": model.externalApp.phase, "plugin": model.externalApp.pluginID ?? "", "message": model.externalApp.message, "familyProcesses":model.externalApp.familyProcesses, "observedWindowID":model.externalApp.observedWindowID ?? -1, "windows":model.externalApp.windowObservations, "screens":NSScreen.screens.map { ["width":$0.frame.width,"height":$0.frame.height] }]
    case "application.inspect":
      guard args.isEmpty else { return failure("invalid-arguments") }
      result=await model.externalApp.inspectAccessibility()
    case "application.closeObservedWindow":
      guard allowPluginManagement, args.isEmpty else { return failure("application-control-not-enabled") }
      accepted=await model.externalApp.closeObservedWindow()
      if !accepted { return failure("application-window-close-unavailable") }
    case "audio.status":
      guard args.isEmpty else { return failure("invalid-arguments") }
      let devices = AudioOutputHardware.devices(), preference = AudioOutputHardware.preference
      let system = devices.first(where: \.systemDefault)
      result["configuredOutput"] = preference.hasPrefix("device:") ? "device" : preference
      result["connectedOutputs"] = devices.count
      result["systemDefaultName"] = text(system?.name ?? "")
      do {
        let explicit = try AudioOutputHardware.resolve()
        let selected = explicit ?? (preference == "system" ? system : nil)
        result["selectionAvailable"] = selected != nil
        if let selected {
          result["selectedOutputName"] = text(selected.name)
          result["selectedHDMI"] = selected.hdmi
          result["selectedIsSystemDefault"] = selected.systemDefault
          result["configuredChannels"] = selected.configuredChannels ?? 0
          result["applicationVolumeRequired"] = AudioOutputHardware.needsApplicationVolume()
          result["ownProcessRunningOnSelectedDevice"] = AudioOutputHardware.processUsesOutput(selected.id, pid: UInt32(ProcessInfo.processInfo.processIdentifier)).map { $0 as Any } ?? NSNull()
        }
      } catch { result["selectionAvailable"] = false; result["selectionError"] = "output-unavailable" }
      result["physicalAudibilityVerified"] = false
    case "nativeMedia.seek":
      guard arguments(["seconds"]), let value = args["seconds"].flatMap(Double.init), model.nativeMedia.seekTo(value) else { return failure("native-media-seek-not-available") }
      accepted = true
    case "gallery.status":
      guard args.isEmpty else { return failure("invalid-arguments") }
      result = await CloudPhotos.shared.statistics()
    case "gallery.preview":
      guard arguments(["id"]), model.section == .bilibili,
        let photoPlugin = model.activePlugin,
        photoPlugin.manifest.nativeLibraries?.contains(where: { ["photos","quark-pictures"].contains($0) }) == true,
        let id = args["id"], let selected = model.online.first(where: { $0.id == id && $0.kind == .photo }),
        let poster = selected.poster, let url = URL(string: poster), url.scheme == "mactv-cloud-photo"
      else { return failure("cloud-photo-not-in-current-gallery") }
      let image = await ArtworkCache.shared.image(for: url)
      guard model.activePlugin?.id == photoPlugin.id, model.online.contains(where: { $0.id == id })
      else { return failure("gallery-changed") }
      result = ["decoded": image != nil, "width": image?.size.width ?? 0, "height": image?.size.height ?? 0]
    case "account.sessionStatus":
      guard arguments(["plugin"]), let plugin = args["plugin"], model.plugins.contains(where: { $0.id == plugin && $0.manifest.authentication != nil }) else { return failure("unknown-account") }
      do {
        let value = try PluginSessionStore().load(pluginID: plugin)
        result = ["configured": value != nil, "perCookieExpiryMetadata": value?.cookieExpiries != nil]
        if let value { result["savedAt"] = value.savedAt; if let expiry = value.expiresAt { result["expiresAt"] = expiry } }
      } catch { return failure("session-status-unavailable") }
    case "input.diagnostics":
      guard args.isEmpty, !model.keyboardSecret else { return failure("nonsecret-input-required") }
      let view = model.systemTextView
      let commands: [[String: Any]]
      if let menu = NSApp.mainMenu {
        SystemDictationCommand.refresh(menu)
        commands = SystemDictationCommand.entries(in: menu).map { ["selector": $0.selector, "enabled": $0.enabled,
          "targetClass": $0.targetClass, "resolvedTargetClass": $0.resolvedTargetClass, "responderTargetClass": $0.responderTargetClass] }
      } else { commands = [] }
      result = ["readiness": model.systemDictationReadiness,
        "nativeClientAttached": view?.window != nil, "nativeClientCurrent": view?.isCurrentTarget == true,
        "nativeClientFirstResponder": view.map { $0.window?.firstResponder === $0 } ?? false,
        "systemMenuPresent": NSApp.mainMenu != nil, "dictationCommands": commands,
        "microphoneStarted": false]
      if let view { result["nativeInputEvents"] = view.nativeInputEvents }
    case "library.list", "module.list":
      guard arguments(["offset", "limit"]), let offset = Int(args["offset"] ?? "0"), let limit = Int(args["limit"] ?? "50"),
        offset >= 0, (1...100).contains(limit) else { return failure("invalid-page") }
      if request.command == "library.list", model.section != .library { return failure("library-not-open") }
      if request.command == "module.list", model.section != .bilibili { return failure("module-not-open") }
      let entries = request.command == "library.list" ? model.visibleItems : model.online
      result = ["total": entries.count, "offset": offset, "items": entries.dropFirst(min(offset, entries.count)).prefix(limit).map(item)]
    case "library.refresh":
      guard arguments(["full"]), args["full"] == nil || ["true", "false"].contains(args["full"]!) else { return failure("invalid-arguments") }
      guard !model.libraryRefreshing else { return failure("library-busy") }
      guard !model.mediaRoot.isEmpty else { return failure("source-not-connected") }
      model.scanLibrary(showFailure: true, forceFull: args["full"] == "true"); accepted = true
      if let scan = model.libraryScanObservation { result["job"] = scan.id.uuidString }
    case "library.inventory":
      guard args.isEmpty, !model.mediaRoot.isEmpty else { return failure("source-not-connected") }
      do {
        let report = LibraryInventoryReport(root: URL(fileURLWithPath: model.mediaRoot), basis: "app-current-model",
          files: model.libraryFilesForMaintenance, matches: try model.metadataStore.load())
        result["summary"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report.summary))
        result["checkPassed"] = report.checkPassed
        result["basis"] = "app-current-model"
      } catch { return failure("inventory-unavailable") }
    case "modules":
      guard args.isEmpty else { return failure("invalid-arguments") }
      result["items"] = model.plugins.map { ["id": $0.id, "title": text($0.title), "available": $0.isAvailable] as [String: Any] }
    case "plugins.list":
      guard args.isEmpty else { return failure("invalid-arguments") }
      do {
        result["items"] = try await PluginClient.packages.installed().map { ["id":$0.id,"version":$0.manifest.version,"enabled":$0.enabled,"origin":$0.origin?.kind ?? "unrecorded","source":$0.origin?.sourceID ?? "","revision":$0.origin?.revision ?? ""] as [String:Any] }
      } catch { return failure("plugin-registry-unavailable") }
    case "plugins.ui.activate":
      guard arguments(["id"]), model.pluginManager.isPresented, let id=args["id"], id != "info",
        let index=model.pluginManager.controls.firstIndex(where:{model.pluginManager.controlID($0)==id}) else { return failure("plugin-control-not-available") }
      model.pluginManager.selection=index; model.pluginManager.activate(); accepted=true
    case "pluginSources.list":
      guard args.isEmpty else { return failure("invalid-arguments") }
      do {
        _ = try PluginSourceServices.configuration.get()
        let list=try await PluginSourceServices.store.sources()
        result["items"]=list.map { ["id":$0.id,"name":text($0.name),"url":$0.repository,"reference":$0.reference,"enabled":$0.enabled] as [String:Any] }
      } catch { return failure("plugin-source-list-unavailable") }
    case "pluginSources.add", "pluginSources.enable", "pluginSources.remove":
      guard allowPluginManagement else { return failure("plugin-management-not-enabled") }
      guard !pluginMutationActive, !model.pluginManager.isPresented else { return failure("plugin-manager-busy") }
      pluginMutationActive=true; defer { pluginMutationActive=false }
      do {
        _ = try PluginSourceServices.configuration.get()
        if request.command=="pluginSources.add" {
          guard arguments(["url"]), let raw=args["url"], !raw.isEmpty else { return failure("invalid-source-url") }
          let source=try await PluginSourceServices.store.add(raw); result["id"]=source.id
        } else {
          guard arguments(["id","enabled"]), let id=args["id"] else { return failure("invalid-arguments") }
          if request.command=="pluginSources.enable" {
            guard let value=args["enabled"], ["true","false"].contains(value) else { return failure("invalid-enabled-state") }
            try await PluginSourceServices.store.setEnabled(id,value=="true")
          } else {
            guard args["enabled"]==nil else { return failure("invalid-arguments") }
            try await PluginSourceServices.store.remove(id)
          }
        }
        accepted=true
      } catch { return failure("plugin-source-mutation-failed") }
    case "pluginSources.catalog", "pluginSources.review":
      guard arguments(["id","origin","plugin"]), let id=args["id"],
        args["origin"]==nil || ["git","bundled"].contains(args["origin"]!) else { return failure("invalid-arguments") }
      if request.command=="pluginSources.review", !allowPluginManagement { return failure("plugin-management-not-enabled") }
      guard !pluginMutationActive, !model.pluginManager.isPresented else { return failure("plugin-manager-busy") }
      pluginMutationActive=true; defer { pluginMutationActive=false }
      do {
        guard let source=try await PluginSourceServices.store.sources().first(where:{$0.id==id && $0.enabled}) else { return failure("source-not-enabled") }
        let bundled=args["origin"]=="bundled"
        let catalog: PluginSourceCatalog
        var revision: String?
        if bundled {
          guard let available=PluginSourceServices.bundledCatalog(for:source) else { return failure("bundled-catalog-not-available") }
          catalog=available
        } else { let snapshot=try await PluginSourceServices.client.catalog(source:source); catalog=snapshot.catalog; revision=snapshot.revision }
        try request.validate()
        if request.command=="pluginSources.catalog" {
          result=["revision":revision ?? "","origin":bundled ? "bundled":"git","name":text(catalog.name),"plugins":catalog.plugins.map { ["id":$0.id,"name":text($0.name),"version":$0.version] }]
        } else {
          guard let plugin=args["plugin"], let entry=catalog.plugins.first(where:{$0.id==plugin}) else { return failure("plugin-not-in-source") }
          guard entry.isCompatible else { return failure("plugin-api-incompatible") }
          let review=try await PluginSourceServices.prepare(entry,source:source,bundled:bundled,revision:revision)
          do { try request.validate(); guard enabled else { throw CancellationError() } }
          catch { await PluginClient.packages.cancel(review.id); return failure("expired-request") }
          pluginReviews=[review.id:review]; pluginReviewSources=[review.id:source]
          result=["review":review.id.uuidString,"origin":bundled ? "bundled":"git","manifest":try JSONSerialization.jsonObject(with:PluginPackageStore.approvalBytes(review.manifest))]
        }
        accepted=true
      } catch let error as PluginGitFailure { return failure("source-git-"+error.kind) }
      catch { return failure("plugin-source-request-failed") }
    case "plugins.review":
      guard allowPluginManagement else { return failure("plugin-management-not-enabled") }
      guard arguments(["directory"]), let path = args["directory"], path.hasPrefix("/"), path.utf8.count <= 8192,
        !pluginMutationActive, !model.pluginManager.isPresented else { return failure("invalid-path-or-plugin-manager-busy") }
      pluginMutationActive = true; defer { pluginMutationActive = false }
      do {
        let review = try await PluginClient.packages.prepare(directory:URL(fileURLWithPath:path,isDirectory:true))
        do { try request.validate(); guard enabled else { throw CancellationError() } }
        catch { await PluginClient.packages.cancel(review.id); return failure("expired-request") }
        pluginReviews = [review.id:review]; pluginReviewSources.removeAll()
        result = ["review":review.id.uuidString,"manifest":try JSONSerialization.jsonObject(with:PluginPackageStore.approvalBytes(review.manifest))]
        accepted = true
      } catch { return failure("plugin-package-review-failed") }
    case "plugins.approve", "plugins.enable", "plugins.remove":
      guard allowPluginManagement else { return failure("plugin-management-not-enabled") }
      guard !pluginMutationActive, !model.pluginManager.isPresented else { return failure("plugin-manager-busy") }
      pluginMutationActive = true; defer { pluginMutationActive = false }
      do {
        if request.command == "plugins.approve" {
          guard arguments(["review"]), let raw = args["review"], let token = UUID(uuidString:raw), let review = pluginReviews[token] else { return failure("unknown-plugin-review") }
          if let source=pluginReviewSources[token] {
            guard try await PluginSourceServices.store.sources().contains(source), source.enabled else {
              await PluginClient.packages.cancel(token); pluginReviews.removeValue(forKey:token); pluginReviewSources.removeValue(forKey:token)
              return failure("source-review-expired")
            }
          }
          model.quiescePlugin(review.manifest.id)
          await PhotoResources.release(owner:review.manifest.id)
          _ = try await PluginClient.packages.approve(token)
          pluginReviews.removeValue(forKey:token)
          pluginReviewSources.removeValue(forKey:token)
        } else {
          guard arguments(["id","enabled"]), let id = args["id"],
            let package = try await PluginClient.packages.installed().first(where: { $0.id == id }) else { return failure("unknown-managed-plugin") }
          try request.validate()
          if request.command == "plugins.enable" {
            guard let value = args["enabled"], ["true","false"].contains(value) else { return failure("invalid-enabled-state") }
            model.quiescePlugin(id)
            await PhotoResources.release(owner:id)
            try await PluginClient.packages.setEnabled(id,value == "true")
          } else {
            guard args["enabled"] == nil else { return failure("invalid-arguments") }
            model.quiescePlugin(id)
            await PhotoResources.release(owner:id)
            if package.manifest.authentication != nil { try PluginSessionStore().remove(pluginID:id) }
            try await PluginClient.packages.remove(id)
          }
        }
        await model.reloadPluginCatalog(); accepted = true
      } catch { return failure("plugin-mutation-failed") }
    case "settings.list":
      guard args.isEmpty else { return failure("invalid-arguments") }
      result["groups"] = TVSetting.groups.enumerated().map { index, group in
        ["group": index + 1, "items": group.map { ["id": String(describing: $0), "title": $0.title, "description": $0.subtitle] }] as [String: Any]
      }
    case "module.open":
      guard arguments(["plugin"]), let plugin = model.plugins.first(where: { $0.id == args["plugin"] }), plugin.isAvailable else { return failure("unknown-module") }
      model.openModule(plugin); accepted = true
    case "bilibili.watchLaterStatus":
      guard args.isEmpty, let plugin = model.plugins.first(where: { $0.id == "mtv.bilibili" && $0.isAvailable }) else {
        return failure("bilibili-unavailable")
      }
      do {
        let data = try await PluginClient.execute(plugin, action: "browse", input: ["channel": "watchLater"], sessionAccess: .stored)
        let page = try JSONDecoder().decode(PluginPage.self, from: data)
        let items = try PluginContentValidator.normalize(page.items, manifest: plugin.manifest)
        result = ["count": items.count, "requiresLogin": page.requiresLogin == true, "hasNext": page.next != nil]
      } catch {
        result = ["error": text(error.localizedDescription)]
      }
    case "module.next":
      guard args.isEmpty, model.section == .bilibili, !model.loading, model.moduleNextPage != nil,
        model.moduleLoadFailure == nil else { return failure("next-page-not-available") }
      model.loadMoreModuleIfNeeded(); accepted = true
    case "item.activate":
      guard arguments(["id"]), [.home, .library, .bilibili].contains(model.section),
        let id = args["id"], let selected = model.visibleItems.first(where: { $0.id == id }) else { return failure("unknown-item") }
      model.activateCard(selected); accepted = true
    case "item.describe":
      guard arguments(["id"]), [.home, .library, .bilibili].contains(model.section),
        let id = args["id"], let selected = model.visibleItems.first(where: { $0.id == id }) else { return failure("unknown-item") }
      var detail = item(selected)
      detail["title"] = text(selected.title); detail["titleTruncated"] = selected.title.count > 2048
      detail["subtitle"] = text(selected.subtitle); detail["overview"] = text(selected.overview)
      detail["overviewTruncated"] = selected.overview.count > 2048
      result["item"] = detail
    case "account.open", "account.importChrome":
      guard arguments(["plugin"]), let plugin = model.plugins.first(where: { $0.id == args["plugin"] }), plugin.manifest.authentication != nil else { return failure("unknown-account-provider") }
      if request.command == "account.importChrome" && !allowAccountImport { return failure("account-import-not-enabled") }
      if request.command == "account.importChrome", !["mtv.quark", "mtv.bilibili"].contains(plugin.id) { return failure("chrome-import-unsupported") }
      if model.login.chromeImportInProgress {
        return failure("account-import-busy")
      }
      model.showLogin(plugin)
      if request.command == "account.importChrome" { model.login.beginLocalChromeImport(allowInteraction: allowAccountInteraction) }
      accepted = true
    case "account.selectProfile":
      guard allowAccountImport else { return failure("account-import-not-enabled") }
      guard arguments(["plugin", "name"]), model.login.plugin?.id == args["plugin"],
        model.login.state == "chromeProfiles", !model.login.chromeProfilesUnavailable,
        let name = args["name"], model.login.selectChromeProfile(named: name, allowInteraction: allowAccountInteraction)
      else { return failure("chrome-profile-not-available") }
      accepted = true
    case "account.close":
      guard args.isEmpty else { return failure("invalid-arguments") }
      model.login.close(); accepted = true
    case "account.revokeMediaSession":
      guard arguments(["plugin"]), args["plugin"] == "mtv.quark" else { return failure("unknown-media-account") }
      MediaSessionApprovalStore().revokeAll(pluginID: "mtv.quark")
      await CloudPhotos.shared.revoke()
      if model.nativeMedia.item?.reference?.hasPrefix("quark:") == true { model.nativeMedia.close() }
      for host in FirstPartyMediaScope.quarkHosts { model.revokedMediaSessionScopes.insert("mtv.quark@" + host) }
      if model.playingItem?.source == "mtv.quark" { model.stopPlayback() }
      accepted = true
    case "account.approveMediaService":
      guard CommandLine.arguments.contains("--allow-media-service-approval"), arguments(["plugin"]), args["plugin"] == "mtv.quark" else { return failure("explicit-service-approval-required") }
      MediaSessionApprovalStore().approveQuarkPlaybackService()
      for host in FirstPartyMediaScope.quarkHosts { model.revokedMediaSessionScopes.remove("mtv.quark@" + host) }
      accepted = true
    case "settings.open":
      guard arguments(["id"]), let setting = TVSetting.allCases.first(where: { String(describing: $0) == args["id"] }),
        TVSetting.groups.flatMap({ $0 }).contains(setting) || [.addFolder, .nas].contains(setting) else { return failure("unknown-setting") }
      model.navigate(.settings); model.performSetting(setting); accepted = true
    case "playback.stop":
      guard args.isEmpty else { return failure("invalid-arguments") }
      model.stopPlayback(); accepted = true
    case "playback.diagnostics":
      guard args.isEmpty, let engine = model.mpvEngine else { return failure("native-diagnostics-not-available") }
      var values: [String: Any] = ["engine": "mpv"]
      if let data=(await engine.startupTimeline()).data(using:.utf8),
        let timeline=try? JSONSerialization.jsonObject(with:data) { values["startupTimeline"]=timeline }
      for key in ["sid", "sub-visibility", "sub-start", "sub-end", "seeking", "paused-for-cache", "demuxer-cache-duration", "hwdec-current", "video-codec", "audio-codec-name", "file-format", "current-ao", "audio-pts", "audio-out-params", "aid", "mute", "volume"] {
        values[key] = text(await engine.diagnostic(key))
      }
      values["subtitleTextCharacters"] = (await engine.diagnostic("sub-text")).count
      if let media = model.originalRemoteMedia {
        let stats = await media.statistics()
        values["transport"] = ["requests":stats.requests,"receivedBytes":stats.received,"prefixHits":stats.prefixHits,
          "chunkBytes":media.transfer.chunkBytes,"depth":media.transfer.depth,"initialDepth":media.transfer.initialDepth,
          "usesSystemProxy":media.transfer.useSystemProxy] as [String:Any]
      }
      if let object = try? JSONSerialization.jsonObject(with: Data((await engine.diagnostic("video-out-params")).utf8)) as? [String: Any] {
        values["video"] = object.filter { ["w", "h", "pixelformat", "hw-pixelformat", "primaries", "gamma", "colormatrix"].contains($0.key) }
      }
      guard model.mpvEngine === engine else { return failure("playback-changed") }
      result = values
    case "playback.tracks":
      guard arguments(["kind"]), let kind = args["kind"], ["audio", "subtitles"].contains(kind),
        model.playbackPresented, !model.preparingPlayback, !model.playbackTracks.busy,
        !model.login.isPresented, !model.keyboardVisible else { return failure("tracks-not-available") }
      model.playerCommand(kind == "audio" ? 3 : 4); accepted = true
    case "playback.selectTrack":
      let menu = model.playbackTracks
      guard arguments(["requestID", "index"]), model.playbackPresented, menu.isPresented, !menu.loading, !menu.busy,
        args["requestID"] == menu.requestID, let index = Int(args["index"] ?? ""), menu.options.indices.contains(index)
      else { return failure("stale-or-invalid-track-selection") }
      menu.selection = index; menu.activate(); accepted = true
    case "playback.toggle":
      guard args.isEmpty, model.playbackPresented else { return failure("playback-not-open") }
      model.playerCommand(1); accepted = true
    case "playback.rate":
      guard arguments(["rate"]), let rate = args["rate"].flatMap(Float.init), model.playbackPresented, model.playbackRates.contains(rate) else { return failure("unsupported-rate") }
      model.applyPlaybackRate(rate); accepted = true
    case "playback.seek":
      guard arguments(["seconds"]), let target = args["seconds"].flatMap(Double.init), target.isFinite,
        model.playbackPresented, target >= 0, target < model.duration,
        model.seekFromTimeline(target) else { return failure("seek-not-available") }
      accepted = true
    default: return failure("unknown-command")
    }
    if accepted {
      var fields: [String: Any] = ["id": request.id.uuidString, "command": request.command]
      // Only validated navigation identifiers are logged, never arbitrary text,
      // profile names, media references, or credential-shaped request arguments.
      if request.command == "input.key", let key = args["key"] { fields["key"] = key }
      if request.command == "navigate", let section = args["section"] { fields["section"] = section }
      if request.command == "settings.open", let setting = args["id"] { fields["setting"] = setting }
      record("command.accepted", fields: fields)
    }
    observe()
    return LocalControlJSON.encode(["schema": 1, "id": request.id.uuidString, "ok": true,
      "accepted": accepted, "state": snapshot(), "result": result])
  }
}

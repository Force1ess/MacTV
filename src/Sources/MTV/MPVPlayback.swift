import AppKit
import Foundation
import MPVBridge
import MTVCore
import SwiftUI

struct MPVPlaybackStats {
  var elapsed: Double, duration: Double
  var paused: Bool, ended: Bool
  var frames: Int
  var vo: String, matrix: String
  var width: Int = 0, height: Int = 0
  var seeking: Bool = false, buffering: Bool = false
}

private actor MPVWorker {
  private var player: OpaquePointer?
  private var externalSubtitleID: Int32?
  private var closed = false
  private var startupOffsetMS: Double?
  private var initialAudioSelected = false
  private func command(_ values: [String]) throws {
    guard let player, !closed else { throw CancellationError() }
    let strings = values.map { strdup($0) }
    defer { strings.forEach { free($0) } }
    let pointers: [UnsafePointer<CChar>?] = strings.map { $0.map { UnsafePointer($0) } } + [nil]
    let status = pointers.withUnsafeBufferPointer { mtv_mpv_command(player,$0.baseAddress) }
    guard status >= 0 else { throw MTVError.message(L("播放操作未能完成（\(status)）")) }
  }
  func value(_ name: String) -> String {
    guard let player, !closed else { return "" }
    var result = [CChar](repeating: 0,count: 65536)
    guard mtv_mpv_property(player,name,&result,Int32(result.count)) == 0 else { return "" }
    return String(cString:result)
  }
  private func observed(_ name: String) -> String {
    guard let player, !closed else { return "" }
    var result=[CChar](repeating:0,count:256)
    guard mtv_mpv_cached_property(player,name,&result,Int32(result.count))==0 else { return "" }
    return String(cString:result)
  }
  func startupTimeline() -> String {
    guard let player, !closed, let offset=startupOffsetMS else { return "{}" }
    var buffer=[CChar](repeating:0,count:8192)
    guard mtv_mpv_startup_trace(player,&buffer,Int32(buffer.count))==0,
      let records=(try? JSONSerialization.jsonObject(with:Data(String(cString:buffer).utf8))) as? [[String:Double]] else { return "{}" }
    let names=[6:"file-start",7:"file-end",8:"file-loaded",17:"video-reconfigured",18:"audio-reconfigured",
      20:"seek",21:"playback-restart",24:"event-overflow",100:"initialized",101:"headers-parsed",
      102:"demuxer-ready",103:"video-decoder-opening",104:"audio-decoder-opening",105:"audio-output-ready",106:"video-output-ready",107:"playback-error"]
    let events:[[String:Any]]=records.map {
      let event=Int($0["event"] ?? -1)
      return ["event":event,"stage":names[event] ?? "other","ms":($0["ms"] ?? 0)+offset]
    }
    let object:[String:Any]=["basis":"click","handleCreationMS":offset,"events":events,"lastErrorCode":mtv_mpv_playback_error(player)]
    return (try? JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])).map { String(decoding:$0,as:UTF8.self) } ?? "{}"
  }
  func begin(url: URL, ownedLoopbackURL: URL?, position: Double, rate: Float, volume: Float, fullscreen: Bool, output: AudioOutputDevice?, paused: Bool, benchmarkStart: Double?) throws {
    let ownedNetwork = url == ownedLoopbackURL && url.scheme == "http" && url.host == "127.0.0.1"
      && url.port.map { $0 >= 1024 } == true && url.path.hasPrefix("/original/") && url.query == nil
    guard !closed, url.isFileURL || ownedNetwork, position.isFinite, position >= 0 else { throw MTVError.message(L("本地播放地址或进度无效")) }
    let library = MPVPlaybackEngine.root.appendingPathComponent("lib/libmpv.2.dylib")
    startupOffsetMS=benchmarkStart.map { (ProcessInfo.processInfo.systemUptime-$0)*1000 }
    guard let handle = mtv_mpv_create(library.path) else { throw MTVError.message(L("MPV组件未能载入：\(String(cString:mtv_mpv_error()))")) }
    player = handle
    if startupOffsetMS != nil { mtv_mpv_enable_diagnostics(handle) }
    if startupOffsetMS != nil, CommandLine.arguments.contains("--benchmark-log-stages") { mtv_mpv_enable_stage_logs(handle) }
    var options = ["config":"no", "load-scripts":"no", "ytdl":"no", "access-references":"no", "sub-auto":"no", "audio-file-auto":"no", "vo":"gpu-next", "gpu-api":"vulkan",
      "gpu-context":"macvk", "hwdec":"auto-safe", "osc":"no", "osd-level":"0", "idle":"yes", "force-window":"immediate",
      "input-default-bindings":"no", "input-vo-keyboard":"no", "input-cursor":"no", "save-position-on-quit":"no", "terminal":"no",
      "resume-playback":"no", "title":AppBrand.name, "border":"no", "geometry":"1280x720", "sid":"auto",
      "slang":SubtitlePreference.playerLanguages, "subs-with-matching-audio":"yes", "subs-fallback":"yes",
      "alang":"", "aid":"auto", "fullscreen":fullscreen ? "yes":"no", "start":String(position), "speed":String(rate),
      "volume":String((AudioOutputHardware.audibleTest ? min(volume, 0.1) : volume) * 100),
      "mute":CommandLine.arguments.contains("--ui-smoke") && !AudioOutputHardware.audibleTest ? "yes":"no",
      "audio-device":output.map { "coreaudio/" + $0.uid } ?? "auto", "pause":paused ? "yes":"no",
      "video-sync":"audio"]
    if ownedNetwork, CommandLine.arguments.contains("--ui-smoke"),
      CommandLine.arguments.contains("--benchmark-no-initial-buffer") {
      options["cache-pause-initial"] = "no"
    }
    for (key,value) in options {
      guard mtv_mpv_option(handle,key,value) >= 0 else { throw MTVError.message(L("MPV不支持所需播放选项：\(key)")) }
    }
    guard mtv_mpv_initialize(handle) >= 0 else { throw MTVError.message(L("MPV GPU播放未能初始化")) }
    try Task.checkCancellation()
    try command(["loadfile",url.isFileURL ? url.path : url.absoluteString,"replace"])
  }
  func stats() throws -> MPVPlaybackStats {
    if !initialAudioSelected,
      let tracks = try? JSONSerialization.jsonObject(with: Data(value("track-list").utf8)) as? [[String:Any]] {
      let audio = tracks.filter { $0["type"] as? String == "audio" }
      if !audio.isEmpty {
        let main = audio.filter { !AudioTrackPreference.isCommentary($0["title"] as? String ?? "") }
        let original = main.first { $0["original"] as? Bool == true || AudioTrackPreference.isOriginal($0["title"] as? String ?? "") }
        let preferred = original ?? main.first { $0["default"] as? Bool == true } ?? main.first
        if let id = preferred?["id"] as? Int { try set("aid",String(id)) }
        initialAudioSelected = true
      }
    }
    if let player, !closed, mtv_mpv_playback_error(player)<0 {
      throw MTVError.message(L("无法继续播放此影片。请重新打开影片后重试。"))
    }
    return MPVPlaybackStats(elapsed:Double(observed("time-pos")) ?? 0,duration:Double(observed("duration")) ?? 0,
      paused:observed("pause") == "yes",ended:observed("eof-reached") == "yes",frames:Int(observed("estimated-frame-number")) ?? 0,
      vo:observed("current-vo"),matrix:observed("video-out-params/colormatrix"),
      width:Int(observed("video-params/w")) ?? 0,height:Int(observed("video-params/h")) ?? 0,
      seeking:observed("seeking") == "yes", buffering:observed("paused-for-cache") == "yes")
  }
  func set(_ property: String, _ value: String) throws { try command(["set",property,value]) }
  func seek(_ position: Double) throws {
    guard position.isFinite, position >= 0 else { throw MTVError.message(L("播放位置无效")) }
    try command(["seek",String(position),"absolute+exact"])
  }
  func tracks(subtitles: Bool) -> PlaybackTrackMenu {
    let data = Data(value("track-list").utf8)
    let list = (try? JSONSerialization.jsonObject(with:data)) as? [[String:Any]] ?? []
    let filtered = list.filter { $0["type"] as? String == (subtitles ? "sub":"audio") }
    var options: [PlaybackTrackOption] = subtitles ? [PlaybackTrackOption(id:-1,title:L("关闭字幕"))] : []
    for track in filtered.prefix(64) {
      guard let id = track["id"] as? Int32 else { continue }
      let title = [track["title"] as? String,track["lang"] as? String,track["codec"] as? String].compactMap{$0}.filter{!$0.isEmpty}.joined(separator:" · ")
      options.append(PlaybackTrackOption(id:id,title:title.isEmpty ? L("轨道 \(id)"):title))
    }
    let selected = filtered.first { $0["selected"] as? Bool == true }?["id"] as? Int32 ?? -1
    return PlaybackTrackMenu(options:options,selectedID:selected,limited:filtered.count > 64)
  }
  func select(subtitles: Bool, id: Int32) throws -> Bool {
    if !subtitles { initialAudioSelected = true }
    guard (subtitles && id == -1) || id > 0 else { return false }
    let property = subtitles ? "sid":"aid", selected = id == -1 ? "no":String(id)
    try set(property,selected)
    return value(property) == selected
  }
  func screenshot(_ file: URL, sourceVideo: Bool = false) throws {
    guard (CommandLine.arguments.contains("--ui-smoke") || CommandLine.arguments.contains("--enable-visual-export")),file.isFileURL else { throw CancellationError() }
    guard observed("seeking") == "no", Int(observed("video-params/w")) ?? 0 > 0 else {
      throw MTVError.message("The current video frame is not ready for capture.")
    }
    try command(["screenshot-to-file",file.path,sourceVideo ? "video":"window"])
  }
  func addSubtitle(_ file: URL) throws -> Int32 {
    try Task.checkCancellation()
    try command(["sub-add", file.path, "select"])
    guard let id = Int32(value("sid")), id > 0 else { throw MTVError.message(L("外挂字幕未能载入")) }
    if let old = externalSubtitleID, old != id { try? command(["sub-remove", String(old)]) }
    externalSubtitleID = id
    return id
  }
  func shutdown() {
    closed = true
    if let player { mtv_mpv_destroy(player) }
    player = nil
  }
}

@MainActor final class MPVPlaybackEngine: ObservableObject {
  nonisolated static var root: URL { Bundle.main.resourceURL!.appendingPathComponent("MPVNativeEngine") }
  nonisolated static var isAvailable: Bool { FileManager.default.fileExists(atPath:root.appendingPathComponent("lib/libmpv.2.dylib").path) }
  private static var activeToken: UUID?
  private let token = UUID(), worker = MPVWorker()
  private var work: Task<Void,Never>?, shutdownWork: Task<Void,Never>?
  private weak var window: NSWindow?, mainWindow: NSWindow?
  private var overlay: NSView?, windowObserver: NSObjectProtocol?
  private var stopped = false
  private(set) var subtitle: PreparedLocalSubtitle?
  private var externalSubtitleID: Int32?
  @Published private(set) var latest: MPVPlaybackStats?
  @Published private(set) var subtitleError: String?
  var onUpdate: ((MPVPlaybackStats)->Void)?, onError: ((String)->Void)?, onClose: (()->Void)?
  func start(url: URL, position: Double, rate: Float, volume: Float, model: AppModel, initiallyPaused: Bool = false, initialSubtitle: PreparedLocalSubtitle? = nil, ownedLoopbackURL: URL? = nil) {
    Self.activeToken = token
    mainWindow = NSApp.windows.first { $0.identifier?.rawValue == "MTVMainWindow" && type(of:$0) == NSWindow.self }
    let previous = Set(NSApp.windows.map(ObjectIdentifier.init))
    let fullscreen = mainWindow?.styleMask.contains(.fullScreen) == true
    let output: AudioOutputDevice?
    do { output = try AudioOutputHardware.resolve() }
    catch { onError?(error.localizedDescription); return }
    let benchmarkStart=model.playbackBenchmark == nil ? nil:model.playbackBenchmarkStarted
    // App-local Vulkan driver selection; never modifies system environment/configuration.
    let driver = Self.root.appendingPathComponent("icd/MoltenVK_icd.json").path
    setenv("VK_DRIVER_FILES",driver,1); setenv("VK_ICD_FILENAMES",driver,1)
    work = Task { [weak self] in
      guard let self else { return }
      do {
        try await worker.begin(url:url,ownedLoopbackURL:ownedLoopbackURL,position:position,rate:rate,volume:volume,fullscreen:fullscreen,output:output,paused:initiallyPaused,benchmarkStart:benchmarkStart)
        for _ in 0..<150 {
          try Task.checkCancellation()
          if let found = NSApp.windows.first(where: { !previous.contains(ObjectIdentifier($0)) && $0.title == AppBrand.name }) {
            window = found; found.identifier = NSUserInterfaceItemIdentifier("MTVMainWindow")
            let view = MPVTransparentHost(rootView:MPVPlaybackOverlay(model:model))
            guard let parent = found.contentView else { throw MTVError.message("MPV播放窗口未准备好") }
            view.frame = parent.bounds; view.autoresizingMask = [.width,.height]
            parent.addSubview(view); overlay = view
            windowObserver = NotificationCenter.default.addObserver(forName:NSWindow.willCloseNotification,object:found,queue:.main) { [weak self] _ in
              Task { @MainActor in if let self,!self.stopped { self.onClose?() } }
            }
            mainWindow?.orderOut(nil)
            found.makeKeyAndOrderFront(nil)
            break
          }
          try await Task.sleep(for:.milliseconds(50))
        }
        guard window != nil else { throw MTVError.message("MPV没有创建可用的GPU播放窗口") }
        var subtitleLoaded = initialSubtitle == nil
        let openingStarted = ProcessInfo.processInfo.systemUptime
        var mediaOpened = false
        while !Task.isCancelled,!stopped {
          let value = try await worker.stats()
          if value.duration > 0 { mediaOpened = true }
          if !mediaOpened, ProcessInfo.processInfo.systemUptime - openingStarted > 15 {
            throw MTVError.message("The player could not open this media stream in time.")
          }
          if !subtitleLoaded, value.duration > 0, value.vo == "gpu-next", let initialSubtitle {
            do { _ = try await loadSubtitle(initialSubtitle) }
            catch { subtitleError = "这份字幕暂时无法载入，可以在字幕菜单重新选择。" }
            subtitleLoaded = true
          }
          latest = value; onUpdate?(value)
          try await Task.sleep(for:.milliseconds(200))
        }
      } catch {
        let timeline=await worker.startupTimeline()
        if model.mpvEngine === self { model.playbackBenchmark?.metadata["nativeStartupTimeline"]=timeline }
        if !stopped, !(error is CancellationError) { onError?(error.localizedDescription) }
      }
    }
  }
  func pause(_ paused: Bool) { Task { try? await worker.set("pause",paused ? "yes":"no") } }
  func seek(_ position: Double) { Task { do { try await worker.seek(position) } catch { onError?(error.localizedDescription) } } }
  func setRate(_ rate: Float) async throws { try await worker.set("speed",String(rate)) }
  func setVolume(_ value: Float) async throws { try await worker.set("volume",String(value * 100)) }
  func setOutput(_ output: AudioOutputDevice?) {
    Task {
      do {
        try await worker.set("audio-device",output.map{"coreaudio/" + $0.uid} ?? "auto")
      } catch { if !stopped { onError?(error.localizedDescription) } }
    }
  }
  func tracks(subtitles: Bool) async -> PlaybackTrackMenu {
    var menu = await worker.tracks(subtitles:subtitles)
    if subtitles, let subtitle, menu.selectedID == externalSubtitleID { menu.selectedExternalURL = subtitle.source.url }
    if subtitles, let subtitleError { menu.message = subtitleError }
    return menu
  }
  func loadSubtitle(_ prepared: PreparedLocalSubtitle) async throws -> Bool {
    do {
      let id = try await worker.addSubtitle(prepared.url)
      guard !stopped else { return false }
      subtitle = prepared; externalSubtitleID = id
      subtitleError = nil
      return true
    } catch {
      if !stopped { subtitleError = "这份字幕暂时无法载入，可以在字幕菜单重新选择。" }
      throw error
    }
  }
  func selectTrack(subtitles: Bool,id: Int32) async -> Bool { (try? await worker.select(subtitles:subtitles,id:id)) == true }
  func diagnostic(_ property: String) async -> String { await worker.value(property) }
  func startupTimeline() async -> String { await worker.startupTimeline() }
  func screenshot(_ file: URL) async throws { try await worker.screenshot(file) }
  func benchmarkVideoFrame(_ file: URL) async throws {
    guard CommandLine.arguments.contains("--ui-smoke"), CommandLine.arguments.contains("--playback-benchmark-only") else { throw CancellationError() }
    try await worker.screenshot(file,sourceVideo:true)
  }
  func windowForTesting() -> NSWindow? { CommandLine.arguments.contains("--ui-smoke") ? window:nil }
  func stop() {
    guard !stopped else { return }; stopped = true; work?.cancel(); work = nil
    if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }; windowObserver = nil
    overlay?.removeFromSuperview(); overlay = nil
    shutdownWork = Task {
      await worker.shutdown()
      subtitle = nil; externalSubtitleID = nil
      if Self.activeToken == token {
        Self.activeToken = nil
        mainWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
      }
    }
  }
  func waitUntilStopped() async { stop(); await shutdownWork?.value }
}

private final class MPVTransparentHost<Content:View>: NSHostingView<Content> { override var isOpaque: Bool { false } }
private struct MPVPlaybackOverlay: View {
  @ObservedObject var model: AppModel
  var body: some View {
    GeometryReader { geometry in
      let scale = min(geometry.size.width / 1280,geometry.size.height / 720)
      ZStack {
        PlayerScreen(model:model,nativeOverlay:true)
        if model.playbackQualityVisible { PlaybackQualityPanel(model: model) }
        if model.playbackSpeedVisible { PlaybackSpeedPanel(model:model) }
        if model.playbackVolumeVisible { PlaybackVolumePanel(model:model) }
        if model.playbackTracks.isPresented { PlaybackTracksPanel(controller:model.playbackTracks) }
        if model.videoPresentation.isPresented { VideoPresentationPanel(controller:model.videoPresentation) }
        if model.episodeChoices != nil { EpisodeContinuationPanel(model:model) }
        if let notice = model.notice { RootView(model:model).noticeOverlay(notice) }
      }.frame(width:1280,height:720).foregroundStyle(.white).preferredColorScheme(.dark)
        .environment(\.colorScheme, .dark)
        .environment(\.tvGlassEnabled, model.glassEnabled).scaleEffect(scale,anchor:.topLeading)
    }
  }
}

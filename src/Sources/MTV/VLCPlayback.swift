import AppKit
import Foundation
import MTVCore
import SwiftUI
import VLCBridge

enum PlaybackEngineChoice: String, CaseIterable {
  case automatic, system, vlc, mpv
  var title: String {
    switch self {
    case .automatic: return "自动选择"
    case .system: return "系统播放"
    case .vlc: return "通用播放 · VLC"
    case .mpv: return "杜比兼容播放 · MPV"
    }
  }
  @MainActor var summary: String {
    switch self {
    case .automatic: return "推荐。根据影片格式与画面设置，自动选择合适的播放器。"
    case .system: return "适合常见视频格式，也用于哔哩哔哩等网络视频。"
    case .vlc: return VLCPlaybackEngine.isAvailable ? "兼容多种影片格式和字幕。" : "尚未安装此播放器组件。"
    case .mpv: return MPVPlaybackEngine.isAvailable ? "支持多种影片格式、音轨与字幕。" : "尚未安装此播放器组件。"
    }
  }
}

struct VLCPlaybackStats {
  let state: Int
  let elapsed: Double
  let duration: Double
  let decodedVideo: Int
  let decodedAudio: Int
  let displayedPictures: Int
  let width: Int
  let height: Int
  let audioOptions: Int
  let subtitleOptions: Int
  let subtitleID: Int
  let audioID: Int
}

private actor VLCWorker {
  private var handle: OpaquePointer?
  private var audioSession: SystemAudioWaveSession?
  private var closed = false
  private var defaultSubtitleSelectionPending = false
  private var seekGeneration = UUID()
  private var audioStrategy = ""
  private var bridgePlayingSince: ContinuousClock.Instant?
  private var subtitle: PreparedLocalSubtitle?
  private var externalSubtitleID: Int32?
  func begin(root: String, url: String, surface: UnsafeMutableRawPointer, muted: Bool, startPosition: Double, reader: VLCContainerReader, subtitle: PreparedLocalSubtitle?, audioAccess: ScopedFileAccess?, automaticSubtitles: Bool) async throws
    -> String
  {
    try Task.checkCancellation()
    guard !closed else { throw CancellationError() }
    guard startPosition.isFinite, startPosition >= 0, startPosition < Double(Int64.max) / 1000 else {
      throw MTVError.message("保存的播放位置无效，请选择从头播放")
    }
    var succeeded = false
    defer { if !succeeded { audioSession?.cancel(); audioSession = nil } }
    if CommandLine.arguments.contains("--ui-smoke"), CommandLine.arguments.contains("--test-vlc-system-audio") {
      guard let file = URL(string: url), file.isFileURL, file.standardizedFileURL == SystemAudioWaveSource.ownedFixtureURL else {
        throw MTVError.message("系统音轨内部验证仅接受自建时间线片源")
      }
      let prepared = try await SystemAudioWaveSession.prepareOwnedFixture(start: startPosition)
      guard !Task.isCancelled, !closed else { prepared.cancel(); throw CancellationError() }
      audioSession = prepared
      audioStrategy = "多段编辑兼容读取 · 系统音轨"
    } else if reader == .avformat, let file = URL(string: url), file.isFileURL {
      if let audioAccess {
        do {
          let prepared = try await SystemAudioWaveSession.prepare(file: file, start: startPosition, access: audioAccess)
          guard !Task.isCancelled, !closed else { prepared.cancel(); throw CancellationError() }
          audioSession = prepared; audioStrategy = "多段编辑兼容读取 · 系统音轨"
        } catch let ineligible as SystemAudioWaveIneligible {
          switch ineligible {
          case .unedited: audioStrategy = "多段视频兼容读取 · 默认音轨"
          case .outsideScope: audioStrategy = "多段编辑兼容读取 · 音轨不在当前所选目录范围，保留原音轨；接缝可能短暂异常"
          case .unsupported(let reason): audioStrategy = "多段编辑兼容读取 · \(reason) · 接缝音频可能短暂异常，可选择系统引擎"
          }
        }
      } else { audioStrategy = "多段编辑兼容读取 · 未取得来源读取范围，保留原音轨；接缝音频可能短暂异常" }
    }
    let output = try AudioOutputHardware.resolve()
    var error = [CChar](repeating: 0, count: 2048)
    guard let player = mtv_vlc_create(root, 0, &error, error.count) else {
      throw MTVError.message(String(cString: error))
    }
    guard !Task.isCancelled, !closed else { mtv_vlc_destroy(player); throw CancellationError() }
    handle = player
    guard !automaticSubtitles || mtv_vlc_prefer_subtitles(player, SubtitlePreference.playerLanguages) == 0 else {
      mtv_vlc_destroy(player); handle = nil; throw MTVError.message("字幕语言设置未能初始化")
    }
    guard mtv_vlc_set_output(player, output.map { String($0.id) }, AudioOutputHardware.audibleTest ? 10 : 100) == 0 else {
      mtv_vlc_destroy(player); handle = nil; throw MTVError.message("声音输出未能初始化，请检查声音输出设置")
    }
    self.subtitle = subtitle
    defaultSubtitleSelectionPending = automaticSubtitles && subtitle == nil
    if CommandLine.arguments.contains("--ui-smoke"), CommandLine.arguments.contains("--test-vlc-audio-content") {
      let fixtureRoot = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/AudioTimeline-v1").path + "/"
      guard let file = URL(string: url), file.isFileURL, file.resolvingSymlinksInPath().path.hasPrefix(fixtureRoot), mtv_vlc_audio_probe_enable(player) == 0 else {
        mtv_vlc_destroy(player); handle = nil; throw MTVError.message("音频内容采集仅接受自建测试目录")
      }
    }
    let testDemux = CommandLine.arguments.contains("--ui-smoke") && CommandLine.arguments.contains("--test-vlc-avformat")
    let testNative = CommandLine.arguments.contains("--ui-smoke") && CommandLine.arguments.contains("--test-vlc-native-reader")
    let selectedReader: VLCContainerReader = testNative ? .native : (testDemux ? .avformat : reader)
    let status: Int32
    if let audioSession { status = mtv_vlc_play_sources(player, url, surface, muted ? 1 : 0, Int64(startPosition * 1000), selectedReader.rawValue, subtitle?.url.absoluteString, audioSession.url.absoluteString) }
    else if let subtitle { status = mtv_vlc_play_subtitle(player, url, surface, muted ? 1 : 0, Int64(startPosition * 1000), selectedReader.rawValue, subtitle.url.absoluteString) }
    else { status = mtv_vlc_play(player, url, surface, muted ? 1 : 0, Int64(startPosition * 1000), selectedReader.rawValue) }
    guard status == 0 else {
      mtv_vlc_destroy(player)
      handle = nil
      throw MTVError.message("VLC 未能启动此片源")
    }
    succeeded = true
    return String(cString: mtv_vlc_version(player))
  }
  func audioStrategySummary() -> String { audioStrategy }
  func stats() async throws -> VLCPlaybackStats? {
    guard let handle else { return nil }
    if let failure = audioSession?.failureMessage { throw MTVError.message(failure) }
    var value = mtv_vlc_stats(handle)
    if defaultSubtitleSelectionPending, value.state == 3 {
      let available = tracks(subtitles: true).options.filter { ($0.trackID ?? -1) >= 0 }
      if let index = SubtitlePreference.preferredIndex(languages: available.map { _ in nil }, titles: available.map(\.title)),
        let id = available[index].trackID, mtv_vlc_select_track(handle, 1, id) == 0 {
        defaultSubtitleSelectionPending = false
        value = mtv_vlc_stats(handle)
      }
    }
    if audioSession != nil, value.state == 3 {
      if bridgePlayingSince == nil { bridgePlayingSince = ContinuousClock().now }
      if mtv_vlc_external_audio_selected(handle) != 1, let began = bridgePlayingSince,
        began.duration(to: ContinuousClock().now) > .seconds(3) {
        throw MTVError.message("系统音轨未能载入，已暂停。可返回选择系统播放引擎。")
      }
    }
    if value.state == 3 || value.state == 4 { await audioSession?.update(seconds: max(0, Double(value.time_ms) / 1000)) }
    if subtitle != nil, externalSubtitleID == nil, value.subtitle_id >= 0 { externalSubtitleID = value.subtitle_id }
    return VLCPlaybackStats(
      state: Int(value.state), elapsed: max(0, Double(value.time_ms) / 1000),
      duration: max(0, Double(value.length_ms) / 1000), decodedVideo: Int(value.decoded_video),
      decodedAudio: Int(value.decoded_audio), displayedPictures: Int(value.displayed_pictures),
      width: Int(value.width), height: Int(value.height), audioOptions: Int(value.audio_count),
      subtitleOptions: Int(value.subtitle_count), subtitleID: Int(value.subtitle_id),
      audioID: Int(value.audio_id))
  }
  func pause(_ paused: Bool) { if let handle { mtv_vlc_pause(handle, paused ? 1 : 0) } }
  func setRate(_ rate: Float) throws {
    guard !closed, let handle, mtv_vlc_set_rate(handle, rate) == 0 else { throw MTVError.message("此片源暂不支持所选倍速") }
  }
  func currentRate() -> Float { handle.map { mtv_vlc_get_rate($0) } ?? 0 }
  func seek(_ seconds: Double) async {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) / 1000, !closed else { return }
    let generation = UUID(); seekGeneration = generation
    await audioSession?.seek(seconds: seconds)
    guard !closed, seekGeneration == generation else { return }
    if let handle { mtv_vlc_seek(handle, Int64(max(0, seconds) * 1000)) }
  }
  func tracks(subtitles: Bool) -> PlaybackTrackMenu {
    guard let handle else { return PlaybackTrackMenu(options: [], selectedID: -1) }
    var values = [MTVVLCTrackOption](repeating: MTVVLCTrackOption(), count: 256)
    var selected: Int32 = -1, limited: Int32 = 0
    let count = values.withUnsafeMutableBufferPointer { mtv_vlc_copy_tracks(handle, subtitles ? 1 : 0, $0.baseAddress, 256, &selected, &limited) }
    if subtitles, subtitle != nil, externalSubtitleID == nil, selected >= 0 { externalSubtitleID = selected }
    var options = values.prefix(Int(count)).map { value in
      let title = withUnsafeBytes(of: value.label) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
      return PlaybackTrackOption(id: value.id, title: title.isEmpty ? "轨道 \(value.id)" : title)
    }
    if subtitles, subtitle != nil {
      options.removeAll { $0.trackID == externalSubtitleID || externalSubtitleID == nil }
    }
    if subtitles { options.insert(PlaybackTrackOption(id: -1, title: "字幕关闭"), at: 0) }
    if !subtitles, audioSession != nil {
      let ready = mtv_vlc_external_audio_selected(handle) == 1
      return PlaybackTrackMenu(options: ready ? [PlaybackTrackOption(id: selected, title: "默认音轨 · 系统解码")] : [],
        selectedID: selected, message: ready ? "" : "系统音轨正在载入")
    }
    return PlaybackTrackMenu(options: options, selectedID: selected, limited: limited != 0,
      selectedExternalURL: subtitles && selected == externalSubtitleID ? subtitle?.source.url : nil,
      message: subtitles && subtitle != nil && externalSubtitleID == nil ? "外挂字幕尚未载入。可关闭字幕，或重新选择其它文件。" : "")
  }
  func selectTrack(subtitles: Bool, id: Int32) -> Bool {
    if subtitles { defaultSubtitleSelectionPending = false }
    guard !Task.isCancelled, let handle else { return false }
    if !subtitles, audioSession != nil {
      guard mtv_vlc_external_audio_selected(handle) == 1, mtv_vlc_stats(handle).audio_id == id else { return false }
    }
    return mtv_vlc_select_track(handle, subtitles ? 1 : 0, id) == 0
  }
  func externalSubtitlePending() async -> Bool { _ = try? await stats(); return subtitle != nil && externalSubtitleID == nil }
  func selectLoadedSubtitle(_ source: URL) -> Bool {
    guard !Task.isCancelled, subtitle?.source.url == source, let handle, let id = externalSubtitleID else { return false }
    return mtv_vlc_select_track(handle, 1, id) == 0
  }
  func snapshot(path: String) -> Bool {
    guard let handle else { return false }
    return mtv_vlc_snapshot(handle, path) == 0
  }
  func audioContent() -> [String: Any] {
    guard let handle, CommandLine.arguments.contains("--ui-smoke"), CommandLine.arguments.contains("--test-vlc-audio-content") else { return [:] }
    var rows = [MTVVLCAudioBlock](repeating: MTVVLCAudioBlock(), count: 256)
    var time: Int64 = 0, clock: Int64 = 0, pause: Int64 = 0
    let count = rows.withUnsafeMutableBufferPointer { mtv_vlc_audio_probe_read(handle, $0.baseAddress, 256, &time, &clock, &pause) }
    return ["mediaTime": Double(time) / 1000, "clockMicroseconds": clock, "pausePTS": pause,
      "systemAudioBridgeSelected": mtv_vlc_external_audio_selected(handle) == 1,
      "blocks": rows.prefix(Int(count)).map { ["ptsMicroseconds": $0.pts_us, "frequencyHz": $0.frequency_hz, "frames": $0.frames, "rms": $0.rms] as [String: Any] }]
  }
  func systemAudioOriginForTesting() -> URL? {
    guard CommandLine.arguments.contains("--ui-smoke") else { return nil }
    return audioSession?.url
  }
  func systemAudioSelectedForTesting() -> Bool {
    guard CommandLine.arguments.contains("--ui-smoke"), let handle else { return false }
    return mtv_vlc_external_audio_selected(handle) == 1
  }
  func setAudioOutput(_ device: AudioOutputDevice?) {
    if let handle {
      var output = [CChar](repeating: 0, count: 128), muted: Int32 = 0, volume: Int32 = 100, played: Int32 = 0
      _ = mtv_vlc_output_status(handle, &output, 128, &muted, &volume, &played)
      _ = mtv_vlc_set_output(handle, device.map { String($0.id) }, volume)
    }
  }
  func setVolume(_ volume: Float) throws {
    guard volume.isFinite, (0...1).contains(volume), !closed, let handle,
      mtv_vlc_set_volume(handle, Int32((volume * 100).rounded())) == 0 else { throw MTVError.message("播放器未能调整音量，请稍后重试") }
  }
  func outputStatus() -> [String: String] {
    guard let handle else { return [:] }
    var device = [CChar](repeating: 0, count: 128), muted: Int32 = -1, volume: Int32 = -1, played: Int32 = 0
    guard mtv_vlc_output_status(handle, &device, 128, &muted, &volume, &played) == 0 else { return [:] }
    return ["device": String(cString: device), "muted": String(muted), "volume": String(volume), "playedBuffers": String(played)]
  }
  func systemAudioPendingReadsForTesting() async -> Int? {
    guard CommandLine.arguments.contains("--ui-smoke") else { return nil }
    return await audioSession?.pendingReadsForTesting()
  }
  func nativeStateForTesting() -> Int? {
    guard CommandLine.arguments.contains("--ui-smoke"), let handle else { return nil }
    return Int(mtv_vlc_stats(handle).state)
  }
  func shutdown() {
    closed = true; seekGeneration = UUID()
    audioSession?.cancel(); audioSession = nil
    if let handle {
      mtv_vlc_destroy(handle)
      self.handle = nil
    }
    subtitle = nil
  }
}

@MainActor final class VLCPlaybackEngine: ObservableObject {
  static var root: URL { Bundle.main.resourceURL!.appendingPathComponent("VLCEngine") }
  static var isAvailable: Bool {
    FileManager.default.fileExists(atPath: root.appendingPathComponent("lib/libvlc.dylib").path)
  }
  @Published private(set) var latest: VLCPlaybackStats?
  @Published private(set) var version = ""
  private(set) var testSeekRequests: [Double] = []
  let initialPosition: Double
  let containerPlan: VLCContainerPlan
  let subtitle: PreparedLocalSubtitle?
  let audioAccess: ScopedFileAccess?
  let initialRate: Float
  let automaticSubtitles: Bool
  var initialVolume: Float = 1
  init(startPosition: Double = 0, containerPlan: VLCContainerPlan = .standard, subtitle: PreparedLocalSubtitle? = nil, audioAccess: ScopedFileAccess? = nil, rate: Float = 1, automaticSubtitles: Bool = true) {
    initialPosition = startPosition; self.containerPlan = containerPlan; self.subtitle = subtitle; self.audioAccess = audioAccess
    initialRate = rate; self.automaticSubtitles = automaticSubtitles
  }
  var onUpdate: ((VLCPlaybackStats) -> Void)?
  var onError: ((String) -> Void)?
  var onAudioStrategy: ((String) -> Void)?
  private let worker = VLCWorker()
  private var task: Task<Void, Never>?
  private var shutdownTask: Task<Void, Never>?
  private var surface: NSView?
  private var source: URL?
  private var started = false
  private var stopped = false
  var surfaceMetrics: [String: Int] {
    guard let surface else { return [:] }
    return [
      "width": Int(surface.bounds.width), "height": Int(surface.bounds.height),
      "attachedToWindow": surface.window == nil ? 0 : 1,
      "visibleVideoSubviews": surface.subviews.filter {
        !$0.isHidden && $0.bounds.width > 0 && $0.bounds.height > 0
      }.count,
    ]
  }
  func start(url: URL) {
    source = url
    prepareIfReady()
  }
  func attach(_ view: NSView) {
    guard surface !== view else { return }
    surface = view
    prepareIfReady()
  }
  private func prepareIfReady() {
    guard !started, !stopped, let surface, let source else { return }
    started = true
    let pointer = Unmanaged.passUnretained(surface).toOpaque()
    let root = Self.root.path
    let worker = worker
    task = Task {
      do {
        try Task.checkCancellation()
        version = try await worker.begin(
          root: root, url: source.absoluteString, surface: pointer,
          muted: CommandLine.arguments.contains("--ui-smoke") && !AudioOutputHardware.audibleTest, startPosition: initialPosition, reader: containerPlan.reader, subtitle: subtitle, audioAccess: audioAccess, automaticSubtitles: automaticSubtitles)
        guard !Task.isCancelled, !stopped else {
          await worker.shutdown()
          return
        }
        onAudioStrategy?(await worker.audioStrategySummary())
        if initialVolume != 1 { try await worker.setVolume(initialVolume) }
        if initialRate != 1 { try await worker.setRate(initialRate) }
        while !Task.isCancelled, !stopped {
          if let value = try await worker.stats() {
            latest = value
            onUpdate?(value)
          }
          try await Task.sleep(for: .milliseconds(200))
        }
      } catch {
        guard !Task.isCancelled, !stopped else { return }
        await worker.pause(true)
        onError?(error.localizedDescription)
      }
    }
  }
  func pause(_ value: Bool) { Task { await worker.pause(value) } }
  func setRate(_ value: Float) async throws { try await worker.setRate(value) }
  func setVolume(_ value: Float) async throws { try await worker.setVolume(value) }
  func currentRate() async -> Float { await worker.currentRate() }
  func seek(_ seconds: Double) {
    if CommandLine.arguments.contains("--ui-smoke"), testSeekRequests.count < 16 { testSeekRequests.append(seconds) }
    Task { await worker.seek(seconds) }
  }
  func tracks(subtitles: Bool) async -> PlaybackTrackMenu { await worker.tracks(subtitles: subtitles) }
  func selectTrack(subtitles: Bool, id: Int32) async -> Bool { await worker.selectTrack(subtitles: subtitles, id: id) }
  func externalSubtitlePending() async -> Bool { await worker.externalSubtitlePending() }
  func selectLoadedSubtitle(_ source: URL) async -> Bool { await worker.selectLoadedSubtitle(source) }
  func snapshot(to url: URL) async -> Bool { await worker.snapshot(path: url.path) }
  func audioContentForTesting() async -> [String: Any] { await worker.audioContent() }
  func systemAudioOriginForTesting() async -> URL? { await worker.systemAudioOriginForTesting() }
  func systemAudioSelectedForTesting() async -> Bool { await worker.systemAudioSelectedForTesting() }
  func setAudioOutput(_ device: AudioOutputDevice?) { Task { await worker.setAudioOutput(device) } }
  func audioOutputStatus() async -> [String: String] { await worker.outputStatus() }
  func systemAudioPendingReadsForTesting() async -> Int? { await worker.systemAudioPendingReadsForTesting() }
  func nativeStateForTesting() async -> Int? { await worker.nativeStateForTesting() }
  func statisticsForTesting() async -> VLCPlaybackStats? {
    guard CommandLine.arguments.contains("--ui-smoke") else { return nil }
    return try? await worker.stats()
  }
  func stop() {
    guard !stopped else { return }
    stopped = true
    task?.cancel()
    task = nil
    let worker = worker
    let retainedSurface = surface
    surface = nil
    // Keep the drawable alive until the vout has finished on its own worker.
    shutdownTask = Task {
      await worker.shutdown()
      withExtendedLifetime(retainedSurface) {}
    }
  }
  func waitUntilStopped() async {
    stop()
    await shutdownTask?.value
  }
}

struct VLCVideoSurface: NSViewRepresentable {
  let engine: VLCPlaybackEngine
  func makeNSView(context: Context) -> NSView {
    let view = NSView()
    view.wantsLayer = true
    view.layer?.backgroundColor = NSColor.black.cgColor
    engine.attach(view)
    return view
  }
  func updateNSView(_ view: NSView, context: Context) { engine.attach(view) }
}

struct PlaybackEnginePicker: View {
  @ObservedObject var model: AppModel
  var body: some View {
    ZStack {
      Color.black.opacity(0.85).ignoresSafeArea()
      VStack(alignment: .leading, spacing: 25) {
        Text("播放器").font(.system(size: 32, weight: .bold))
        ForEach(Array(PlaybackEngineChoice.allCases.enumerated()), id: \.offset) { index, choice in
          TVButton(
            selected: model.enginePickerIndex == index, action: { model.selectEngine(choice) },
            hover: { model.enginePickerIndex = index }
          ) {
            HStack {
              VStack(alignment: .leading, spacing: 8) {
                Text(choice.title).font(.system(size: 23, weight: .semibold))
              }
              Spacer()
              if model.preferredEngine == choice { Image(systemName: "checkmark").font(.title2) }
            }.padding(24).frame(maxWidth: .infinity)
          }
        }
      }.padding(40).frame(width: 860).background(
        .ultraThickMaterial, in: RoundedRectangle(cornerRadius: 30))
    }
  }
}

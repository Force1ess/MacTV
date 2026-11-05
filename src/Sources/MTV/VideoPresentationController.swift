import AVFoundation
import AVKit
import AppKit
import MTVCore

struct PlaybackDisplayInfo: Codable, Equatable {
  let name: String
  let currentEDR: Double
  let potentialEDR: Double
  let systemHDREligible: Bool
}

@MainActor final class VideoPresentationController: ObservableObject {
  @Published private(set) var isPresented = false
  @Published private(set) var preference: VideoRangeChoice
  @Published private(set) var signal: VideoSourceSignal?
  @Published private(set) var signalMessage = "尚未读取片源信息"
  @Published private(set) var display: PlaybackDisplayInfo?
  @Published var selection = 0
  private var inspection: Task<Void, Never>?
  private var generation = UUID()
  private var systemEngine = false
  var onDismiss: (() -> Void)?
  var supportsModes: Bool {
    if #available(macOS 26.0, *) { return systemEngine }
    return false
  }
  var count: Int { supportsModes ? VideoRangeChoice.allCases.count + 1 : 1 }
  init() {
    preference = VideoRangeChoice(rawValue: UserDefaults.standard.string(forKey: "mtv.videoRange") ?? "automatic") ?? .automatic
  }
  func present(systemEngine: Bool) {
    TVPointerFocus.remoteInput()
    self.systemEngine = systemEngine
    selection = supportsModes ? VideoRangeChoice.allCases.firstIndex(of: preference) ?? 0 : 0
    refreshDisplay()
    isPresented = true
  }
  func move(_ step: Int) { selection = min(max(0, selection + step), count - 1) }
  func activate() {
    if supportsModes, VideoRangeChoice.allCases.indices.contains(selection) {
      setPreference(VideoRangeChoice.allCases[selection])
    }
    close()
  }
  func setPreference(_ value: VideoRangeChoice) {
    preference = value
    if !CommandLine.arguments.contains("--ui-smoke") {
      UserDefaults.standard.set(value.rawValue, forKey: "mtv.videoRange")
    }
  }
  func close() { isPresented = false; onDismiss?() }
  func refreshDisplay() {
    let window = NSApp.windows.first { $0.identifier?.rawValue == "MTVMainWindow" }
    guard let screen = window?.screen else { display = nil; return }
    display = PlaybackDisplayInfo(name: screen.localizedName,
      currentEDR: Double(screen.maximumExtendedDynamicRangeColorComponentValue),
      potentialEDR: Double(screen.maximumPotentialExtendedDynamicRangeColorComponentValue),
      systemHDREligible: AVPlayer.eligibleForHDRPlayback)
  }
  func reset() {
    generation = UUID(); inspection?.cancel(); inspection = nil
    isPresented = false; signal = nil; signalMessage = "当前引擎尚未提供片源色彩信息"
  }
  func inspect(_ item: AVPlayerItem) {
    reset()
    let request = generation
    signalMessage = "正在读取片源色彩信息…"
    inspection = Task { [weak self, weak item] in
      guard let self, let item else { return }
      do {
        guard let track = try await item.asset.loadTracks(withMediaType: .video).first else {
          throw MTVError.message("未找到视频轨道")
        }
        let (formats, rate, characteristics) = try await track.load(.formatDescriptions, .nominalFrameRate, .mediaCharacteristics)
        try Task.checkCancellation()
        guard generation == request else { return }
        guard let format = formats.first else { throw MTVError.message("没有可用的视频格式描述") }
        let raw = CMFormatDescriptionGetMediaSubType(format)
        let bytes = [UInt8((raw >> 24) & 255), UInt8((raw >> 16) & 255), UInt8((raw >> 8) & 255), UInt8(raw & 255)]
        let codec = String(bytes: bytes, encoding: .ascii) ?? "未知"
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        let properties = (CMFormatDescriptionGetExtensions(format) as? [String: Any]) ?? [:]
        let atoms = properties[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] as? [String: Any] ?? [:]
        let dolby = codec == "dvh1" || codec == "dvhe" || ["dvcC", "dvvC"].contains {
          (atoms[$0] as? Data).map { $0.count >= 4 } == true
        }
        signal = VideoSourceSignal(codec: codec, width: Int(dimensions.width), height: Int(dimensions.height),
          framesPerSecond: rate.isFinite && rate > 0 ? Double(rate) : nil,
          primaries: properties[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String,
          transferFunction: properties[kCMFormatDescriptionExtension_TransferFunction as String] as? String,
          containsHDR: characteristics.contains(.containsHDRVideo), dolbyVisionSignaled: dolby)
        signalMessage = "片源标记，不代表当前输出格式"
      } catch {
        guard generation == request, !Task.isCancelled else { return }
        signalMessage = "片源信息不可用：" + error.localizedDescription
      }
    }
  }
}

extension VideoRangeChoice {
  @available(macOS 26.0, *) var avDisplayRange: AVDisplayDynamicRange {
    switch self {
    case .automatic: return .automatic
    case .standard: return .standard
    case .high: return .high
    }
  }
}

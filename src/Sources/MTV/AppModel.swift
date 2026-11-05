import AVFoundation
import AppKit
import Combine
import CoreImage
import MTVCore
import SwiftUI

private extension String {
  var nonEmptySourceTitle: String { isEmpty ? "影片文件夹" : self }
}

enum Section: String, CaseIterable {
  case home = "首页"
  case library = "影片"
  case bilibili = "哔哩哔哩"
  case extensions = "应用"
  case settings = "设置"
}
enum InputAction {
  case up, down, left, right, select, back, menu, home
  case text(String)
  case delete
}

enum TextEntryTarget: Hashable {
  case search, overviewSearch, smbAddress, smbUsername, smbPassword, metadataQuery, metadataToken, localPath, pluginPath, pluginSourceURL, pluginSourceReference, moduleReference
}

struct LibraryScanObservation: Codable {
  let id: UUID
  let root: String
  let startedAt: Double
  var phase = "running"
  var completedAt: Double?
  var entries: Int?
  var unavailable: Int?
  var limited: Bool?
  var failureDomain: String?
  var failureCode: Int?
}

@MainActor final class AppModel: ObservableObject {
  var mediaFocusLayout: MediaFocusLayout?
  let login = LoginController()
  let dictationKey = RemoteDictationKey()
  let externalApp = ExternalAppSession()
  let nativeMedia = NativeMediaController()
  private var nativeMediaSubscription: AnyCancellable?
  private var externalAppSubscription: AnyCancellable?
  let pinyin = PinyinEngine()
  let videoPresentation = VideoPresentationController()
  let playbackTracks = PlaybackTracksController()
  private var playbackTracksSubscription: AnyCancellable?
  private var videoPresentationSubscription: AnyCancellable?
  let smb = SMBController()
  let metadata = MetadataController()
  let automaticMetadata = AutomaticMetadataController()
  let libraryMaintenance = LibraryMaintenance()
  let localFolders = LocalFolderController()
  let sourceSetup = SourceSetupController()
  let savedSources = SavedSourcesController()
  let pluginManager = PluginManagerController()
  let pluginFolders = LocalFolderController()
  private var pluginManagerSubscription: AnyCancellable?
  private var pluginFolderSubscription: AnyCancellable?
  private var pluginCatalogGeneration = UUID()
  let libraryOverview = LibraryOverviewController()
  let libraryBrowser = LibraryBrowseController()
  private var libraryBrowseSubscription: AnyCancellable?
  @Published private(set) var libraryBrowseOptions = LibraryBrowseOptions()
  private var rootBrowseCache: (options: LibraryBrowseOptions, query: String, items: [MediaItem])?
  private var overviewSubscription: AnyCancellable?
  private var pendingOverviewItem: (selection: LibrarySourceSelection, id: String, generation: UUID, returnTo: SavedContentReturn?)?
  lazy var continueWatching = ContinueWatchingController(store: resumeStore)
  lazy var watchlist = WatchlistController(store: resumeStore)
  private var watchlistSubscription: AnyCancellable?
  private var historySubscription: AnyCancellable?
  var savedContentReturn: SavedContentReturn?
  var historyReturnEntryID: String? { savedContentReturn?.shelf == .history ? savedContentReturn?.id : nil }
  private var historyOpenID = UUID()
  private var returnToOverview = false
  private var overviewOpenID = UUID()
  private var savedSourcesSubscription: AnyCancellable?
  var sourceStore: LibrarySourceStore
  @Published private(set) var sourceNeedsSetup = false
  @Published private(set) var sourceError: String?
  private var sourceSetupSubscription: AnyCancellable?
  private var sourceSaveTask: Task<Void, Never>?
  private var sourceSaveID = UUID()
  private var sourceSwitchID = UUID()
  private var savingSource = false
  private var localFolderSubscription: AnyCancellable?
  var smokeKeyRoute: [String: String] = [:]
  private var automaticMetadataSubscription: AnyCancellable?
  var metadataStore = MetadataStore()
  @Published private(set) var metadataCacheError: String?
  private var metadataRecords: [String: MetadataMatch] = [:]
  private var localizedSeries: [Int: MetadataCandidate] = [:]
  private var seriesLocalizationAttempts: [Int: Date] = [:]
  private var seriesLocalizationTask: Task<Void, Never>?
  private var rawLibrary: [MediaItem] = []
  var libraryFilesForMaintenance: [MediaItem] { rawLibrary }
  private var scanIncremental: LibraryIncrementalState?
  private var scanIncrementalContext: String?
  @Published private(set) var libraryReusedCount = 0
  @Published private(set) var libraryNFOReadCount = 0
  @Published private(set) var libraryMetadataFailureCount = 0
  var libraryIndex: LibraryIndexStore
  var smbLibraryIndex: SMBLibraryIndexStore
  let resumeStore: PlaybackResumeStore
  @Published private(set) var libraryStatus = ""
  @Published private(set) var libraryIndexedAt: Date?
  @Published private(set) var libraryIndexError: String?
  @Published private(set) var libraryRefreshing = false
  @Published private(set) var libraryNeedsAttention = false
  private var libraryScanWorker: Task<LibraryScanResult, Error>?
  private var libraryCommitTask: Task<Void, Never>?
  private var libraryScanTimeout: Task<Void, Never>?
  private var metadataSubscription: AnyCancellable?
  private var loginSubscription: AnyCancellable?
  private var pinyinSubscription: AnyCancellable?
  private var smbSubscription: AnyCancellable?
  private var activeSMBShares: [MountedSMBShare] = []
  private var currentSMBBoundary: URL?
  private var currentSMBProfile: SMBProfile?
  private var currentSMBAddress = ""
  private var smbMountInvalid = false
  private struct PendingSMBPlayback { let id: String; let fromBeginning: Bool }
  private var pendingSMBPlayback: PendingSMBPlayback?
  private let networkPath = NetworkPathObserver()
  private var networkRecovery = SMBNetworkRecovery()
  var needsSMBReconnect: Bool { (currentSMBProfile != nil || !currentSMBAddress.isEmpty) && (currentSMBBoundary == nil || smbMountInvalid) }
  var hasLibrarySource: Bool { !mediaRoot.isEmpty || currentSMBProfile != nil }
  var smbReconnectColumn: Int { libraryPath.isEmpty ? 1 : 3 }
  var savedSourcesColumn: Int { needsSMBReconnect ? 2 : 1 }
  var overviewColumn: Int { 2 + (needsSMBReconnect ? 1 : 0) }
  var libraryBrowseColumn: Int { overviewColumn + 1 }
  var mediaSourceDisplay: String {
    if let profile = currentSMBProfile { return profile.address }
    return currentSMBBoundary == nil ? (mediaRoot.isEmpty ? "尚未选择影片目录" : mediaRoot) : currentSMBAddress
  }
  struct LibrarySourceSnapshot {
    let incremental: LibraryIncrementalState?
    let incrementalContext: String?
    let path: String
    let files: [MediaItem]
    let boundary: URL?
    let smbProfile: SMBProfile?
    let smbAddress: String
    let status: String
    let indexedAt: Date?
    let warning: Bool
    let indexError: String?
    let mountInvalid: Bool
  }
  func captureLibrarySource() -> LibrarySourceSnapshot {
    LibrarySourceSnapshot(incremental: scanIncremental, incrementalContext: scanIncrementalContext,
      path: mediaRoot, files: rawLibrary, boundary: currentSMBBoundary,
      smbProfile: currentSMBProfile, smbAddress: currentSMBAddress,
      status: libraryStatus, indexedAt: libraryIndexedAt, warning: libraryNeedsAttention,
      indexError: libraryIndexError, mountInvalid: smbMountInvalid)
  }
  func restoreLibrarySource(_ snapshot: LibrarySourceSnapshot) {
    scanIncremental = snapshot.incremental; scanIncrementalContext = snapshot.incrementalContext
    sourceSwitchID = UUID(); pendingOverviewItem = nil; libraryOverview.close()
    libraryCommitTask?.cancel()
    pendingSMBPlayback = nil
    libraryScanID = UUID()
    libraryScanWorker?.cancel()
    libraryScanTimeout?.cancel()
    loading = false
    libraryRefreshing = false
    mediaRoot = snapshot.path
    currentSMBBoundary = snapshot.boundary
    currentSMBProfile = snapshot.smbProfile
    currentSMBAddress = snapshot.smbAddress
    smbMountInvalid = snapshot.mountInvalid
    libraryStatus = snapshot.status
    libraryIndexedAt = snapshot.indexedAt
    libraryNeedsAttention = snapshot.warning
    libraryIndexError = snapshot.indexError
    applyLibraryItems(snapshot.files)
  }
  func releaseInactiveSMBShares() async {
    guard !playbackPresented, !loading else { return }
    let old = activeSMBShares.filter { $0.mount != currentSMBBoundary }
    let reports = await SMBMountClient.retire(old, deadline: 1)
    let removed = Set(reports.filter { $0.outcome == "removed" }.map(\.mountID))
    activeSMBShares.removeAll { removed.contains($0.mount.lastPathComponent) }
    ArtworkRefresh.shared.setSMBShares(activeSMBShares)
  }
  private func currentValidatedSMBShare(_ boundary: URL?) throws -> MountedSMBShare? {
    guard let boundary else { return nil }
    guard let share = activeSMBShares.first(where: { $0.mount.standardizedFileURL.path == boundary.standardizedFileURL.path }) else { throw SMBFailure.mountChanged(3) }
    try share.validateCurrentMount()
    return share
  }
  private func markSMBMountUnavailable(_ error: Error) {
    guard currentSMBBoundary != nil else { return }
    smbMountInvalid = true; libraryNeedsAttention = true; networkRecovery.failed()
    pendingSMBPlayback = nil
    if playbackSourceID == "local" { stopPlayback() }
    libraryStatus = L("共享连接已失效，已保留索引；请重新连接。")
    ArtworkRefresh.shared.setSMBShares(activeSMBShares)
    let profile = currentSMBProfile, attempt = sourceSwitchID
    if let profile {
      let store = smbLibraryIndex
      Task {
        guard let snapshot = try? await store.load(profile: profile), sourceSwitchID == attempt,
          currentSMBProfile == profile, smbMountInvalid else { return }
        applyLibraryItems(snapshot.offlineItems(), preservingPosition: true); libraryIndexedAt = snapshot.scannedAt
      }
    }
  }
  @Published var section: Section = .home
  let information = AboutMacTV()
  private var informationSubscription: AnyCancellable?
  @Published var setupGuideVisible = false
  @Published var mediaSessionConsent: MediaSessionConsent?
  @Published var mediaSessionConsentSelection = 1
  var testMediaSessionApprovals = Set<String>()
  var revokedMediaSessionScopes = Set<String>()
  @Published var guideInputDevices: InputDeviceInventory?
  @Published var appearance = TVAppearance(rawValue: UserDefaults.standard.string(forKey: "mtv.appearance") ?? "dark") ?? .dark
  @Published var glassEnabled = UserDefaults.standard.object(forKey: "mtv.glass") as? Bool ?? true
  @Published var appearanceVisible = false
  @Published var appearanceSelection = 0
  @Published var settingsSidebarFocus = true
  @Published var navigationTabs = TVNavigationTab.load()
  @Published var navigationCustomizationVisible = false
  @Published var navigationCustomizationIndex = 0
  @Published var settingsGroup = 1
  var sourceEditorReturnsToSavedSources = false
  @Published var setupGuideStep = 0
  @Published var setupGuideSelection = 0
  @Published var lastDictationRequest = "idle"
  @Published var accountSettingsVisible = false
  @Published var accountSettingsIndex = 0
  private var playbackFilesByFolder: [URL: [MediaItem]] = [:]
  @Published var library: [MediaItem] = [] {
    didSet {
      let files = library.compactMap { item -> (URL, MediaItem)? in
        guard item.source == "local", item.localMetadata?.sourceReachable != false,
          let file = item.url.flatMap(URL.init(string:)), file.isFileURL else { return nil }
        return (file.deletingLastPathComponent().standardizedFileURL, item)
      }
      playbackFilesByFolder = Dictionary(grouping: files, by: { $0.0 }).mapValues {
        $0.map { $0.1 }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
      }
    }
  }
  @Published var libraryCatalog = LibraryCatalog()
  @Published var libraryPath: [MediaItem] = []
  private struct LibraryPosition {
    let section: Section
    let query: String
    let row: Int
    let column: Int
  }
  private var libraryHistory: [LibraryPosition] = []
  @Published var online: [MediaItem] = []
  @Published var plugins: [PluginRecord] = []
  @Published var pluginIssues: [String] = []
  @Published var activePlugin: PluginRecord?
  @Published var bilibiliChannel: BilibiliChannel = .home
  var hasBilibiliTabs: Bool { section == .bilibili && activePlugin?.id == "mtv.bilibili" }
  var hasModuleSubnavigation: Bool { hasBilibiliTabs || (section == .bilibili && activePlugin?.id == "mtv.quark") }
  var moduleToolbarRow: Int { 1 }
  let bilibiliChannelRow = 2
  @Published var moduleNextPage: String?
  @Published var moduleNeedsLogin = false
  @Published var modulePath: [MediaItem] = []
  struct ModuleLoadFailure {
    let pluginID: String
    let action: String
    let input: [String: String]
    let append: Bool
    let path: [String]
    let query: String
    let message: String
  }
  @Published private(set) var moduleLoadFailure: ModuleLoadFailure?
  var moduleHasFooter: Bool { moduleNextPage != nil || moduleLoadFailure != nil }
  private struct ModuleSnapshot {
    let items: [MediaItem]
    let next: String?
    let query: String
    let failure: ModuleLoadFailure?
    let row: Int
    let column: Int
    let savedDetail: MediaItem?
    let savedReturn: SavedContentReturn?
  }
  private var moduleHistory: [ModuleSnapshot] = []
  var moduleSessionAccess: PluginClient.SessionAccess = .stored
  @Published var focus = FocusGrid(rows: [5, 1, 4])
  @Published var detail: MediaItem?
  @Published var detailAction = 0
  @Published var notice: String?
  @Published private var foregroundLoading = false
  var loading: Bool {
    get { foregroundLoading || libraryRefreshing }
    set { foregroundLoading = newValue }
  }
  @Published var search = ""
  weak var systemTextView: MTVSystemTextView?
  @Published var keyboardSession = UUID()
  @Published var keyboardVisible = false {
    didSet { if keyboardVisible && !oldValue { keyboardSession = UUID() } }
  }
  @Published private(set) var textEntryTarget: TextEntryTarget = .search {
    didSet { keyboardSession = UUID() }
  }
  @Published private var keyboardDraft = ""
  @Published var keyboardSymbols = false
  private var savedKeyboardMode: (Bool, Bool)?
  private var moduleLookupOwner: String?
  var inputText: String {
    get { textEntryTarget == .search ? search : keyboardDraft }
    set { if textEntryTarget == .search { search = newValue } else { keyboardDraft = newValue } }
  }
  var keyboardSecret: Bool { textEntryTarget == .smbPassword || textEntryTarget == .metadataToken }
  var keyboardRows: [[String]] {
    let content = keyboardSymbols ? KeyboardLayout.symbols : Array(KeyboardLayout.rows.dropLast())
    return content + [
      keyboardSecret ? ["大小写", "符号", "空格", "退格", "清空", "完成"] : Array(KeyboardLayout.rows.last!.dropLast()) + ["听写", "完成"]
    ]
  }
  var keyboardDisplayText: String {
    keyboardSecret ? String(repeating: "•", count: inputText.count) : inputText
  }
  var keyboardTitle: String {
    switch textEntryTarget {
    case .search: return L("搜索")
    case .overviewSearch: return L("搜索全部资料库")
    case .smbAddress: return L("服务器地址")
    case .smbUsername: return L("Username")
    case .smbPassword: return L("密码")
    case .metadataQuery: return L("查找影片信息")
    case .metadataToken: return L("TMDB 访问令牌")
    case .localPath: return L("影片目录路径")
    case .pluginPath: return L("插件文件夹路径")
    case .pluginSourceURL: return L("Git Repository URL")
    case .pluginSourceReference: return L("Git Branch or Tag")
    case .moduleReference: return L("打开视频编号或链接")
    }
  }
  @Published var keyboardFocus = FocusGrid(rows: KeyboardLayout.rows.map(\.count))
  @Published var composing = ""
  @Published var chinese = (Bundle.main.preferredLocalizations.first ?? "en").hasPrefix("zh")
  @Published var uppercase = false
  @Published var candidateIndex = 0
  @Published var candidateFocus = false
  @Published var player: AVPlayer?
  @Published var vlcEngine: VLCPlaybackEngine?
  @Published var mpvEngine: MPVPlaybackEngine?
  @Published var preferredEngine: PlaybackEngineChoice
  @Published var enginePickerVisible = false
  @Published var audioOutputVisible = false
  @Published var audioOutputIndex = 0
  @Published var audioOutputDevices: [AudioOutputDevice] = []
  @Published var enginePickerIndex = 0
  @Published private(set) var preparingPlayback = false
  var playbackBenchmark: PlaybackBenchmarkRecord?
  var playbackBenchmarkStarted = 0.0
  var benchmarkTimeObserver: NSKeyValueObservation?
  @Published private(set) var playbackSelectionReason = ""
  private var preflightTask: Task<Void, Never>?
  private var preparationWatchdog: Task<Void, Never>?
  private var remoteMedia: PreparedRemoteMedia?
  private(set) var originalRemoteMedia: OriginalRemoteMedia?
  private var pendingRemoteResources: [RemoteHeaderStream] = []
  private var smokePreparationTrace: Task<Void, Never>?
  private var smokeTimeoutGeneration: UUID?
  var smokePlaybackResolution: [String: Any] = [:]
  var smokePlaybackFailureDetails: [[String: Any]] = []
  private var preflightGeneration = UUID()
  @Published var playbackTitle = ""
  @Published var playbackState = ""
  @Published private(set) var playbackInterruption: String?
  @Published var playbackInterruptionButton = 0
  private var playbackInterruptionIsFailure = false
  var playbackInterruptionTitle: String { playbackInterruptionIsFailure ? "暂时无法播放" : "正在等待媒体" }
  private var playbackRetryItem: MediaItem?
  private var playbackRetryFromBeginning = false
  private var protectsUnverifiedResume = false
  private var systemResumeAttempted = false
  private var playbackHealthTask: Task<Void, Never>?
  private var playbackProgress = PlaybackProgressMonitor()
  @Published var elapsed = 0.0
  @Published var duration = 0.0
  @Published var paused = false
  @Published var playerButton = 1
  @Published var playbackQualityVisible = false
  @Published var qualitySelection = 0
  @Published var bilibiliQualityOptions: [PlaybackQualityOption] = []
  @Published var bilibiliActualQuality: Int?
  @Published var bilibiliActualQualityTitle = ""
  @Published var bilibiliQualityNote = ""
  var bilibiliQualityPreference = CommandLine.arguments.contains("--ui-smoke") ? "auto" : (UserDefaults.standard.string(forKey: "mtv.bilibili.quality") ?? "auto")
  var pendingQualityResume: PlaybackQualityResume?
  @Published var playerControlsVisible = true {
    didSet { TVPointerFocus.setPlaybackCursorHidden(playbackPresented && !playerControlsVisible) }
  }
  @Published var playerTimelineFocused = false
  @Published var playerScrub: PlayerScrubDraft?
  @Published var playerSeekPreview: Double?
  var playerSeekTicket: UUID?
  var playerSeekPreviewTask: Task<Void, Never>?
  var timelineFrameForTesting: CGRect?
  @Published var mediaRoot: String
  private var observer: NSKeyValueObservation?
  private var playbackEndFailureObserver: NSObjectProtocol?
  private var playbackCompletionObserver: NSObjectProtocol?
  @Published private(set) var playbackCompleted = false
  @Published private(set) var nextEpisodePlan: EpisodeContinuationPlan?
  @Published private(set) var episodeChoices: EpisodeContinuationPlan?
  @Published var episodeChoiceIndex = 0
  private var modulePlaybackContinuation: ModulePlaybackContinuation?
  @Published private(set) var checkingModuleContinuation = false
  private var moduleContinuationGeneration = UUID()
  private var moduleContinuationTask: Task<Void, Never>?
  private var playbackResolveTask: Task<Void, Never>?
  var checkingContinuationLabel: String { modulePlaybackContinuation?.value.label ?? "后续内容" }
  func moduleContinuationDiagnosticsForTesting() -> [String: String] {
    guard CommandLine.arguments.contains("--ui-smoke"), let value = modulePlaybackContinuation else { return [:] }
    return ["currentReference": value.value.currentReference, "collectionReference": value.value.collectionReference,
      "sessionAccess": value.sessionAccess == .guest ? "guest" : "stored", "currentID": value.currentID]
  }
  var playerControlIndices: [Int] { [10, 0, 1, 2, 7, 3, 4, 8] + (hasBilibiliQualityMenu ? [11] : []) }
  @Published private(set) var loadingNextVideo = false
  func adjacentVideo(_ direction: Int) -> MediaItem? {
    guard let current = playingItem else { return nil }
    let videos: [MediaItem]
    if current.source == "local" {
      guard let url = current.url.flatMap(URL.init(string:)), url.isFileURL else { return nil }
      let folder = url.deletingLastPathComponent().standardizedFileURL
      videos = playbackFilesByFolder[folder] ?? []
    } else {
      guard activePlugin?.id == current.source else { return nil }
      videos = online.filter { item in
        item.source == current.source && (item.kind == nil || item.kind == .video)
      }
    }
    guard let index = videos.firstIndex(where: { $0.id == current.id }),
      videos.indices.contains(index + direction) else { return nil }
    return videos[index + direction]
  }
  private var canLoadNextVideoPage: Bool {
    guard let item = playingItem, item.source != "local", activePlugin?.id == item.source else { return false }
    return online.contains { $0.id == item.id } && moduleNextPage != nil && moduleLoadFailure == nil
  }
  var hasNextVideo: Bool { adjacentVideo(1) != nil || canLoadNextVideoPage }
  func canStepVideo(_ direction: Int) -> Bool {
    !loadingNextVideo && (direction > 0 ? hasNextVideo : adjacentVideo(-1) != nil)
  }
  func stepVideo(_ direction: Int) {
    guard canStepVideo(direction) else { return }
    if let item = adjacentVideo(direction) { openAdjacentVideo(item); return }
    let request = playbackRequestID
    loadingNextVideo = true
    Task {
      defer {
        loadingNextVideo = false
        if playbackRequestID == request, playbackCompleted { returnAfterPlayback() }
      }
      for _ in 0..<20 {
        guard playbackPresented, playbackRequestID == request, canLoadNextVideoPage else { return }
        loadMoreModuleIfNeeded()
        await loadTask?.value
        guard playbackPresented, playbackRequestID == request else { return }
        if let item = adjacentVideo(1) { openAdjacentVideo(item); return }
        if let failure = moduleLoadFailure { notice = failure.message; return }
      }
    }
  }
  private func openAdjacentVideo(_ item: MediaItem) {
    detail = nil
    let sessionAccess = modulePlaybackContinuation?.sessionAccess
    play(item, sessionAccessOverride: sessionAccess, switchingVideo: true)
  }
  var playerControlCount: Int { playerControlIndices.count }
  @Published var playbackRate: Float = 1
  @Published var playbackSpeedVisible = false
  @Published var playbackSpeedIndex = 1
  let playbackRates: [Float] = [0.5, 1, 1.25, 1.5, 1.75, 2]
  var playingItem: MediaItem? { playbackRetryItem }
  @Published var playbackVolume: Float = 1
  @Published var playbackVolumeVisible = false
  @Published var playbackVolumeSelection = 1
  var lastNonzeroVolume: Float = 1
  private var volumeMonitor: Any?
  private var systemVolumeObserver: SystemVolumeObserver?
  var observedSystemVolume: Float? = nil
  var observedSystemMute = false
  private var timeObserver: Any?
  private var currentMediaID: String?
  private var playbackSourceID: String?
  private var testVideoOutput: AVPlayerItemVideoOutput?
  private var keyMonitor: Any?
  private var pointerMonitor: Any?
  private var returnGestureMonitor: Any?
  private var loadTask: Task<Void, Never>?
  private var playbackWatchdog: Task<Void, Never>?
  private var controlsTask: Task<Void, Never>?
  private var moduleGeneration = UUID()
  private(set) var playbackRequestID = UUID() {
    didSet { if mediaSessionConsent?.requestID != playbackRequestID { mediaSessionConsent = nil } }
  }
  private(set) var libraryScanObservation: LibraryScanObservation?
  private var libraryScanID = UUID() {
    didSet {
      if let observation = libraryScanObservation, observation.id != libraryScanID,
        ["running", "readComplete"].contains(observation.phase) {
        libraryScanObservation?.phase = "cancelled"
        libraryScanObservation?.completedAt = Date().timeIntervalSince1970
      }
    }
  }
  private var lastSavedSecond = 0
  var hasUserSubtitleChoice = false
  var hasUserAudioChoice = false
  var automaticSubtitleTask: Task<Void, Never>?
  var localSubtitleContext: LocalSubtitlePlaybackContext?
  let subtitleFiles = LocalSubtitleReader()
  private var retiringVLC: [VLCPlaybackEngine] = []
  private var retiringMPV: [MPVPlaybackEngine] = []
  private var resumeModuleOnLoginDismiss = false
  var playbackPresented: Bool { player != nil || vlcEngine != nil || mpvEngine != nil }
  var candidates: [String] { pinyin.state.candidates }
  var candidateActions: [String] {
    guard !candidates.isEmpty else { return [] }
    return candidates + (pinyin.state.page > 0 ? ["上一页"] : [])
      + (!pinyin.state.lastPage ? ["下一页"] : [])
  }
  var homePlugins: [PluginRecord] {
    plugins.filter { $0.manifest.presentation?.showOnHome == true }
  }
  var moduleTitle: String { activePlugin?.title ?? "应用" }
  var navigationSection: Section {
    section == .bilibili && activePlugin?.id != "mtv.bilibili" ? .extensions : section
  }
  var moduleSupportsSearch: Bool { activePlugin?.manifest.capabilities.contains("search") == true }
  var moduleSupportsLookup: Bool { activePlugin?.manifest.capabilities.contains("lookup") == true }
  var moduleLookupColumn: Int { hasBilibiliTabs || activePlugin?.manifest.authentication == nil ? 1 : 2 }
  var moduleAccountColumn: Int { hasBilibiliTabs && moduleSupportsLookup ? 2 : 1 }
  var moduleLocationTitle: String {
    ([moduleTitle] + modulePath.map(\.title)).joined(separator: "  ›  ")
  }
  var modulePrimaryTitle: String {
    if !modulePath.isEmpty { return "返回上层" }
    return moduleSupportsSearch ? (search.isEmpty ? "搜索影片…" : search) : "刷新内容"
  }
  func modulePrimaryAction() {
    if !modulePath.isEmpty {
      _ = backModuleFolder()
    } else if moduleSupportsSearch {
      showKeyboard()
    } else {
      loadModule()
    }
  }
  var filtered: [MediaItem] {
    if section == .bilibili { return online }
    if section == .library && libraryPath.isEmpty {
      if let cached = rootBrowseCache, cached.options == libraryBrowseOptions, cached.query == search { return cached.items }
      let candidates = libraryCatalog.root + (search.isEmpty ? [] : library.filter { $0.localMetadata?.episode != nil })
      let values = libraryBrowseOptions.apply(candidates, query: search)
      rootBrowseCache = (libraryBrowseOptions, search, values)
      return values
    }
    var items =
      section == .library
      ? currentLibraryItems
      : libraryCatalog.root
    if !search.isEmpty, libraryPath.isEmpty {
      items += library.filter { $0.localMetadata?.episode != nil }
    }
    return search.isEmpty
      ? items
      : items.filter {
        $0.title.localizedCaseInsensitiveContains(search)
          || $0.subtitle.localizedCaseInsensitiveContains(search)
      }
  }
  var visibleItems: [MediaItem] { section == .home ? Array(filtered.prefix(24)) : filtered }
  var currentLibraryItems: [MediaItem] {
    guard let parent = libraryPath.last else { return libraryCatalog.root }
    return libraryCatalog.displayedChildren(of: parent)
  }
  var gridColumns: Int { section == .bilibili || (section == .library && !libraryPath.isEmpty) ? 4 : 6 }
  var mediaRows: [[MediaItem]] {
    let items = visibleItems
    let columns = gridColumns
    return stride(from: 0, to: items.count, by: columns).map {
      Array(items[$0..<min($0 + columns, items.count)])
    }
  }
  var selectedHero: MediaItem? {
    if section == .home, focus.row >= homeMediaOffset {
      let index = (focus.row - homeMediaOffset) * 6 + focus.column
      if index < visibleItems.count { return visibleItems[index] }
    }
    return libraryCatalog.root.first
  }

  init() {
    if CommandLine.arguments.contains("--ui-smoke") || CommandLine.arguments.contains("--qa-volatile-history") {
      let args = CommandLine.arguments
      let scope = args.firstIndex(of: "--history-test-scope").flatMap { $0 + 1 < args.count ? UUID(uuidString: args[$0 + 1]) : nil }
      resumeStore = scope.map { .isolated(scope: $0) } ?? .isolated()
    } else { resumeStore = PlaybackResumeStore() }
    let testSession = "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString.prefix(8))"
    smbLibraryIndex = CommandLine.arguments.contains("--ui-smoke")
      ? SMBLibraryIndexStore(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/MTV/TestResults/smb-index-test-\(testSession)"), artwork: SMBArtworkCache(disk: ArtworkCache.shared.disk))
      : SMBLibraryIndexStore(artwork: SMBArtworkCache(disk: ArtworkCache.shared.disk))
    let sourceFile = CommandLine.arguments.contains("--ui-smoke")
      ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/MTV/TestResults/source-test-\(testSession).json")
      : LibrarySourceStore.normalFile
    sourceStore = LibrarySourceStore(file: sourceFile)
    savedSources.store = SavedLibrarySourcesStore(file: sourceFile.deletingPathExtension().appendingPathExtension("saved.json"))
    let indexFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      CommandLine.arguments.contains("--ui-smoke")
        ? "Library/Application Support/MTV/TestResults/index-test-\(testSession).json"
        : "Library/Application Support/MTV/Library/index.json")
    libraryIndex = LibraryIndexStore(file: indexFile)
    launchLog.notice("App model initialized")
    // Engine overrides are diagnostic-only; ordinary playback always follows
    // the format policy, including for users who once selected legacy VLC.
    preferredEngine = CommandLine.arguments.contains("--ui-smoke")
      ? (PlaybackEngineChoice(rawValue: UserDefaults.standard.string(forKey: "playbackEngine") ?? "automatic") ?? .automatic)
      : .automatic
    mediaRoot = ""
    if !CommandLine.arguments.contains("--ui-smoke") {
      libraryBrowseOptions = LibraryBrowseOptions(
        kind: LibraryBrowseKind(rawValue: UserDefaults.standard.string(forKey: "mtv.library.kind") ?? "all") ?? .all,
        order: LibraryBrowseOrder(rawValue: UserDefaults.standard.string(forKey: "mtv.library.order") ?? "title") ?? .title)
    }
    if CommandLine.arguments.contains("--ui-smoke"),
      let index = CommandLine.arguments.firstIndex(of: "--smb-offline-test-scope"), index + 1 < CommandLine.arguments.count,
      let id = UUID(uuidString: CommandLine.arguments[index + 1]) {
      let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/MTV/TestResults/SMBOfflineStartup-" + id.uuidString.lowercased())
      sourceStore = LibrarySourceStore(file: root.appendingPathComponent("source.json"))
      smb.profileStore = SMBProfileStore(file: root.appendingPathComponent("connections.json"))
      smbLibraryIndex = SMBLibraryIndexStore(root: root.appendingPathComponent("indexes"), artwork: SMBArtworkCache(disk: ArtworkCache.shared.disk))
      libraryIndex = LibraryIndexStore(file: root.appendingPathComponent("unused-local-index.json"))
    }
    informationSubscription = information.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    sourceSetupSubscription = sourceSetup.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    savedSourcesSubscription = savedSources.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    pluginManagerSubscription = pluginManager.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    pluginFolderSubscription = pluginFolders.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    pluginFolders.title = "选择插件文件夹"
    pluginFolders.shortcutTitle = "下载"
    pluginFolders.shortcutURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
    pluginFolders.onSelect = { [weak self] directory in self?.pluginManager.prepare(directory) }
    pluginFolders.onAddress = { [weak self] in self?.showPluginPath() }
    pluginFolders.onSystemPicker = { [weak self] in self?.choosePluginUsingSystemPanel() }
    pluginManager.onAdd = { [weak self] in
      guard let self else { return }; self.pluginFolders.present(at: self.pluginFolders.shortcutURL)
    }
    pluginManager.onAddSource = { [weak self] in self?.showPluginSourceInput(reference:false) }
    pluginManager.onSourceReference = { [weak self] in self?.showPluginSourceInput(reference:true) }
    pluginManager.onWillChange = { [weak self] id in self?.quiescePlugin(id) }
    pluginManager.onRegistryWillChange = { [weak self] in
      guard let self else { return }
      for plugin in self.plugins where !plugin.id.hasPrefix("mtv.") { self.quiescePlugin(plugin.id) }
    }
    pluginManager.onChanged = { [weak self] in await self?.reloadPluginCatalog() }
    overviewSubscription = libraryOverview.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    libraryOverview.onOpen = { [weak self] source, itemID in self?.openOverviewSource(source, itemID: itemID) }
    libraryOverview.onNavigationIntent = { [weak self] in self?.overviewOpenID = UUID() }
    libraryBrowseSubscription = libraryBrowser.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    libraryBrowser.onApply = { [weak self] value in self?.applyLibraryBrowse(value) }
    savedSources.onSelect = { [weak self] selection, title in self?.selectSavedSource(selection, title: title) }
    savedSources.onAddLocal = { [weak self] in
      self?.sourceEditorReturnsToSavedSources = true; self?.chooseRoot()
    }
    savedSources.onAddNAS = { [weak self] in
      self?.sourceEditorReturnsToSavedSources = true; self?.smb.present()
    }
    savedSources.onWillRemove = { [weak self] in await self?.waitForSourceSave() }
    savedSources.onRemoved = { [weak self] source, remaining in self?.removedLibrarySource(source, remaining: remaining) }
    sourceSetup.onChoose = { [weak self] choice in
      guard let self else { return }
      switch choice {
      case .local: self.chooseRoot()
      case .nas: self.smb.present()
      case .applications: self.continueWithoutLocalSource(destination: .extensions)
      case .later: self.continueWithoutLocalSource(destination: .home)
      }
    }
    loginSubscription = login.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send()
    }
    pinyinSubscription = pinyin.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    videoPresentationSubscription = videoPresentation.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    videoPresentation.onDismiss = { [weak self] in self?.showPlayerControls() }
    playbackTracksSubscription = playbackTracks.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    playbackTracks.onDismiss = { [weak self] in self?.showPlayerControls() }
    smbSubscription = smb.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    smb.onEdit = { [weak self] field in self?.showSMBTextEntry(field) }
    smb.onFailureDetails = { [weak self] message in self?.notice = message }
    smb.onConnectionFailure = { [weak self] automatic in
      self?.networkRecovery.failed()
      if automatic {
        self?.libraryStatus = L("自动重连未完成，请手动检查连接或 macOS 访问提示")
        self?.libraryNeedsAttention = true
      }
    }
    smb.onProfileSaved = { [weak self] profile in
      guard let self, let current = self.currentSMBProfile, current.id == profile.id else { return }
      guard current.sameAccount(as: profile), current.address == profile.address else { self.networkRecovery.deactivate(); return }
      self.currentSMBProfile = profile
      if self.currentSMBBoundary != nil { self.networkRecovery.activate(profile) }
      else { self.networkRecovery.deactivate() }
    }
    metadataSubscription = metadata.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    metadata.onEditQuery = { [weak self] in self?.showMetadataQuery() }
    metadata.onEditToken = { [weak self] in self?.showMetadataToken() }
    metadata.onApply = { [weak self] item, candidate in
      try self?.applyMetadata(item: item, candidate: candidate)
    }
    automaticMetadataSubscription = automaticMetadata.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    automaticMetadata.onReview = { [weak self] item in self?.presentMetadata(for: item) }
    localFolderSubscription = localFolders.objectWillChange.sink { [weak self] _ in
      self?.objectWillChange.send()
    }
    localFolders.onSelect = { [weak self] url in self?.useLocalRoot(url) }
    localFolders.onAddress = { [weak self] in self?.showLocalPath() }
    localFolders.onSystemPicker = { [weak self] in self?.chooseRootUsingSystemPanel() }
    localFolders.onDismiss = { [weak self] in
      self?.sourceEditorCancelled()
    }
    smb.onDismiss = { [weak self] in
      self?.pendingSMBPlayback = nil
      self?.sourceEditorCancelled()
    }
    automaticMetadata.onMatch = { [weak self] item, candidate in
      guard let self else { return false }
      let existing = try self.metadataStore.load()
      guard
        AutomaticMetadata.targets(files: self.rawLibrary, matches: existing).contains(where: {
          $0.id == item.id
        })
      else { return false }
      let inserted = try self.metadataStore.insertAutomatic(targetID: item.id, candidate: candidate)
      if inserted { self.applyLibraryItems(self.rawLibrary, preservingPosition: true) }
      return inserted
    }
    smb.onSelect = { [weak self] share, folder, profile in
      guard let self else { return }
      self.sourceEditorReturnsToSavedSources = false
      do { try share.validateCurrentMount() }
      catch { self.notice = error.localizedDescription; Task { await SMBMountClient.disconnect(share) }; return }
      self.sourceSwitchID = UUID()
      let firstSelection = self.sourceNeedsSetup
      self.sourceNeedsSetup = false
      if let profile { self.persistSourceSelection(LibrarySourceSelection(smbProfileID: profile.id), title: profile.address) }
      else if firstSelection {
        self.persistSourceSelection(LibrarySourceSelection(path: nil))
      }
      self.activeSMBShares.append(share)
      ArtworkRefresh.shared.setSMBShares(self.activeSMBShares)
      self.currentSMBBoundary = share.mount
      self.smbMountInvalid = false
      self.currentSMBProfile = profile
      if let profile { self.networkRecovery.activate(profile) } else { self.networkRecovery.deactivate() }
      self.currentSMBAddress = profile?.address ?? self.smb.address
      self.mediaRoot = folder.path
      self.libraryIndexedAt = nil
      self.libraryIndexError = nil
      self.navigate(.library)
      self.applyLibraryItems([])
      if let profile {
        let attempt = UUID()
        self.libraryScanID = attempt
        self.libraryRefreshing = true
        Task {
          do {
            if let snapshot = try await self.smbLibraryIndex.load(profile: profile) {
              try share.validateCurrentMount()
              let items = try snapshot.binding(profile: profile, mount: share.mount)
              guard self.libraryScanID == attempt, self.currentSMBBoundary == share.mount else { return }
              self.applyLibraryItems(items)
              self.libraryIndexedAt = snapshot.scannedAt
            }
          } catch { if self.libraryScanID == attempt {
            self.libraryIndexError = error.localizedDescription
            if (error as? SMBFailure)?.stage == .mountValidation { self.markSMBMountUnavailable(error) }
          } }
          guard self.libraryScanID == attempt, self.currentSMBBoundary == share.mount else { return }
          if self.smbMountInvalid { self.libraryRefreshing = false; return }
          self.scanLibrary()
        }
      } else { self.scanLibrary() }
    }
    login.onMediaSessionRevoked = { [weak self] in
      guard let self else { return }
      for host in FirstPartyMediaScope.quarkHosts { self.revokedMediaSessionScopes.insert("mtv.quark@" + host) }
      self.mediaSessionConsent = nil
      if self.nativeMedia.item?.reference?.hasPrefix("quark:") == true { self.nativeMedia.close() }
      Task { await CloudPhotos.shared.revoke() }
      if self.playingItem?.source == "mtv.quark" { self.stopPlayback() }
    }
    login.onDismiss = { [weak self] plugin, changed in
      guard let self, self.section == .bilibili, self.activePlugin?.id == plugin.id else { return }
      let resume = self.resumeModuleOnLoginDismiss
      self.resumeModuleOnLoginDismiss = false
      if changed || resume {
        self.loadModule(
          action: self.search.isEmpty ? "browse" : "search", input: ["query": self.search])
      }
    }
  }
  func start() {
    systemVolumeObserver = SystemVolumeObserver { [weak self] state in
      guard let self else { return }
      self.observedSystemVolume = state.volume; self.observedSystemMute = state.muted
      self.nativeMedia.systemVolumeScale = self.systemPlaybackGain
      if self.playbackPresented { self.setPlaybackVolume(self.playbackVolume) }
    }
    nativeMediaSubscription = nativeMedia.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    externalApp.onIssue = { [weak self] message in self?.notice = message }
    externalAppSubscription = externalApp.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    historySubscription = continueWatching.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    continueWatching.onUpdate = { [weak self] previous in self?.historyDidUpdate(previous) }
    continueWatching.onOpen = { [weak self] entry in self?.openSavedContent(entry.context, shelf: .history) }
    watchlistSubscription = watchlist.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    watchlist.onUpdate = { [weak self] previous in self?.watchlistDidUpdate(previous) }
    watchlist.onOpen = { [weak self] context in self?.openSavedContent(context, shelf: .watchlist) }
    if !CommandLine.arguments.contains("--ui-smoke") {
      networkPath.start { [weak self] reachable in Task { @MainActor in self?.handleNetworkPath(reachable: reachable) } }
    }
    pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
      if event.window?.identifier?.rawValue == "MTVMainWindow" {
        TVPointerFocus.pointerMoved()
        if self?.playbackPresented == true { self?.showPlayerControls() }
      }
      return event
    }
    do {
      let catalog = try PluginCatalog.load(
        root: PluginClient.root, developerMode: CommandLine.arguments.contains("--developer-mode"))
      plugins = catalog.plugins
      pluginIssues = catalog.issues
    } catch { pluginIssues = [error.localizedDescription] }
    Task { await reloadPluginCatalog() }
    volumeMonitor = NSEvent.addLocalMonitorForEvents(matching: .systemDefined) { [weak self] event in
      guard let self, NSApp.isActive, NSApp.keyWindow?.attachedSheet == nil,
        (self.playbackPresented || self.nativeMedia.item?.kind == .audio), event.subtype.rawValue == 8,
        AudioOutputHardware.needsApplicationVolume(), self.observedSystemVolume == nil else { return event }
      let key = (event.data1 >> 16) & 0xffff, state = (event.data1 >> 8) & 0xff
      guard [0, 1, 7].contains(key) else { return event }
      if self.nativeMedia.item?.kind == .audio {
        if state == 0x0a { self.nativeMedia.volumeKey(key) }; return nil
      }
      if state == 0x0a {
        if key == 7 { self.togglePlaybackMute() }
        else { self.adjustPlaybackVolume(key == 0 ? 0.0625 : -0.0625) }
      }
      return nil
    }
    returnGestureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.swipe, .rightMouseUp, .otherMouseUp]) { [weak self] event in
      guard NSApp.isActive, event.window?.identifier?.rawValue == "MTVMainWindow",
        event.window?.attachedSheet == nil else { return event }
      if event.type == .rightMouseUp || (event.type == .otherMouseUp && event.buttonNumber == 3)
        || (event.type == .swipe && event.deltaX > 0 && abs(event.deltaX) > abs(event.deltaY)) {
        self?.handle(.back); return nil
      }
      return event
    }
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
      if CommandLine.arguments.contains("--ui-smoke") {
        self?.smokeKeyRoute = [
          "active": String(NSApp.isActive),
          "eventWindow": event.window?.identifier?.rawValue ?? "nil",
          "keyWindow": NSApp.keyWindow?.identifier?.rawValue ?? "nil",
          "sheet": String(event.window?.attachedSheet != nil),
          "keyCode": String(event.keyCode),
        ]
      }
      let voiceWindow = event.window ?? NSApp.keyWindow
      if NSApp.isActive, voiceWindow?.identifier?.rawValue == "MTVMainWindow",
        voiceWindow?.attachedSheet == nil, let self {
        if self.keyboardVisible, self.dictationKey.consume(event, onTrigger: {
          if !self.login.isPresented && !self.keyboardSecret { self.requestSystemDictation() }
        }) { return nil }
      }
      guard event.type == .keyDown else { return event }
      guard NSApp.isActive, event.window?.identifier?.rawValue == "MTVMainWindow",
        event.window?.attachedSheet == nil, !event.modifierFlags.contains(.command)
      else { return event }
      let action: InputAction?
      if let navigation = TVKeyBindings.navigationAction(keyCode: event.keyCode, keyboardVisible: self?.keyboardVisible == true) {
        action = navigation
      } else {
        if event.charactersIgnoringModifiers == "\u{F729}" {
          action = .home
        } else if let text = event.characters, !text.isEmpty,
          text.unicodeScalars.allSatisfy({
            !$0.properties.isDefaultIgnorableCodePoint && $0.value >= 32 && $0.value < 0xF700
          })
        {
          if self?.keyboardVisible == true {
            action = .text(text)
          } else if text == "c" {
            action = .menu
          } else if text == " " {
            action = .select
          } else {
            action = nil
          }
        } else {
          action = nil
        }
      }
      if let action {
        self?.handle(action)
        return nil
      }
      return event
    }
    // Navigation is usable before any asynchronous library restore, including
    // first launch without a source and isolated tests. Count the voice action.
    rebuildFocus(reset: true)
    libraryMaintenance.start(model: self)
    // Isolated owned-fixture tests do not need access to the user's real disk.
    // The full suite and ordinary launch still initialize the selected source.
    if CommandLine.arguments.contains("--ui-smoke"),
      ["--documentation-preview", "--system-dictation-only", "--system-text-input-only", "--owned-regression", "--source-management-only", "--modern-playback-only", "--tv-refinement-only", "--player-timeline-only", "--playback-quality-only", "--bilibili-playback-only", "--library-maintenance-only", "--library-organization-only", "--chrome-login-only"].contains(where: CommandLine.arguments.contains) {
      return
    }
    initializeLibrarySource()
  }
  func initializeLibrarySource() {
    networkRecovery.deactivate()
    libraryCommitTask?.cancel()
    libraryScanWorker?.cancel()
    libraryScanTimeout?.cancel()
    let attempt = UUID()
    libraryScanID = attempt
    libraryRefreshing = true
    let store = sourceStore
    let smoke = CommandLine.arguments.contains("--ui-smoke")
    let fresh = smoke && (CommandLine.arguments.contains("--fresh-install-smoke") || CommandLine.arguments.contains("--smb-offline-startup-read"))
    let legacy = fresh ? nil : UserDefaults.standard.string(forKey: "mediaRoot")
    let migrationIndex = fresh ? libraryIndex : LibraryIndexStore()
    Task {
      do {
        if smoke && !fresh, try await store.load() == nil, let normal = try await LibrarySourceStore().load() {
          try await store.save(normal)
        }
        let saved = try await store.resolve(legacyPath: legacy, index: migrationIndex)
        guard libraryScanID == attempt else { return }
        sourceError = nil
        sourceNeedsSetup = saved == nil
        if let profileID = saved?.smbProfileID {
          let profiles = try await smb.profileStore.load()
          guard let profile = profiles.first(where: { $0.id == profileID }) else { throw MTVError.message("已选 NAS 连接不存在，请重新选择来源") }
          let snapshot = try await smbLibraryIndex.load(profile: profile)
          guard libraryScanID == attempt else { return }
          currentSMBProfile = profile; currentSMBBoundary = nil; currentSMBAddress = profile.address
          mediaRoot = ""
          applyLibraryItems(snapshot?.offlineItems() ?? [])
          libraryIndexedAt = snapshot?.scannedAt
          libraryStatus = snapshot == nil ? L("NAS 尚未连接；连接后建立资料库") : L("NAS 尚未连接；已恢复 \(snapshot!.records.count) 个缓存条目")
          if let skipped = snapshot?.artworkSkippedCount, skipped > 0 { libraryStatus += L("；\(skipped) 张封面未缓存") }
          libraryNeedsAttention = true
          libraryRefreshing = false
          launchLog.notice("Offline NAS index restored; entries=\(snapshot?.records.count ?? 0)")
          await releaseInactiveSMBShares()
        } else if let saved, let path = saved.path {
          currentSMBProfile = nil; currentSMBBoundary = nil; currentSMBAddress = ""
          mediaRoot = path
          launchLog.notice("Library source restored; origin=\(saved.origin.rawValue, privacy: .public)")
          restoreLibraryFromIndex()
        } else {
          currentSMBProfile = nil; currentSMBBoundary = nil; currentSMBAddress = ""
          mediaRoot = ""
          applyLibraryItems([])
          libraryStatus = ""; libraryIndexedAt = nil; libraryNeedsAttention = false
          libraryRefreshing = false
          if saved == nil {
            if !CommandLine.arguments.contains("--ui-smoke"), !UserDefaults.standard.bool(forKey:"mtv.setup.seen") { presentSetupGuide() }
            else { presentSourceSetup() }
          }
        }
      } catch {
        guard libraryScanID == attempt else { return }
        libraryRefreshing = false
        currentSMBProfile = nil; currentSMBBoundary = nil; currentSMBAddress = ""
        mediaRoot = ""; applyLibraryItems([])
        sourceError = error.localizedDescription
        sourceNeedsSetup = true
        presentSourceSetup()
      }
    }
  }
  func presentSourceSetup() { sourceSetup.present() }
  /// Removing the active folder changes MTV's selection only. Cached indexes,
  /// media files, NAS credentials and watch history remain on disk.
  func removedLibrarySource(_ removed: SavedLibrarySource, remaining: [SavedLibrarySource]) {
    let active = currentSMBProfile.map { LibrarySourceSelection(smbProfileID: $0.id) }
      ?? LibrarySourceSelection(path: mediaRoot.isEmpty ? nil : mediaRoot)
    guard removed.matches(active) else { return }
    if playbackPresented || preparingPlayback { stopPlayback() }
    libraryMaintenance.sourceChanged()
    sourceSwitchID = UUID()
    pendingOverviewItem = nil
    libraryOverview.close()
    libraryScanID = UUID()
    libraryScanWorker?.cancel(); libraryScanTimeout?.cancel(); libraryCommitTask?.cancel()
    libraryRefreshing = false
    currentSMBBoundary = nil; currentSMBProfile = nil; currentSMBAddress = ""
    smbMountInvalid = false; networkRecovery.deactivate(); pendingSMBPlayback = nil
    mediaRoot = ""; libraryIndexedAt = nil; libraryIndexError = nil
    libraryNeedsAttention = false; sourceNeedsSetup = false
    libraryPath = []; libraryHistory = []
    libraryStatus = L("选择或添加影片文件夹")
    applyLibraryItems([])
    // An explicit empty choice prevents legacy preferences or the old index
    // from migrating the just-removed folder back into the source list.
    persistSourceSelection(LibrarySourceSelection(path: nil))
    if let fallback = remaining.first(where: { source in
      guard let path = source.path else { return false }
      var directory: ObjCBool = false
      return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
    }) ?? remaining.first(where: { $0.smbProfileID != nil }) {
      selectSavedSource(fallback.selection, title: fallback.title)
    }
    Task { await releaseInactiveSMBShares() }
  }
  func presentSavedSources() {
    let current: LibrarySourceSelection?
    if let profile = currentSMBProfile { current = LibrarySourceSelection(smbProfileID: profile.id) }
    else if currentSMBBoundary == nil, !mediaRoot.isEmpty { current = LibrarySourceSelection(path: mediaRoot) }
    else { current = nil }
    savedSources.present(current: current, title: currentSMBProfile?.address
      ?? URL(fileURLWithPath: mediaRoot).lastPathComponent.nonEmptySourceTitle)
  }
  func selectSavedSource(_ selection: LibrarySourceSelection, title: String = "NAS", opening itemID: String? = nil, returnTo: SavedContentReturn? = nil) {
    pendingOverviewItem = nil
    savedSources.close()
    let switchID = UUID()
    sourceSwitchID = switchID
    if let path = selection.path {
      stopPlayback(); useLocalRoot(URL(fileURLWithPath: path, isDirectory: true), title: title)
      if let itemID { pendingOverviewItem = (selection, itemID, sourceSwitchID, returnTo) }
      return
    }
    guard let profileID = selection.smbProfileID else { return }
    Task {
      do {
        let profiles = try await smb.profileStore.load()
        guard sourceSwitchID == switchID else { return }
        guard profiles.contains(where: { $0.id == profileID }) else {
          throw MTVError.message("此来源的 NAS 连接已删除，请重新添加或移除该来源")
        }
        stopPlayback()
        persistSourceSelection(selection, title: title)
        let request = sourceSaveID
        await waitForSourceSave()
        guard sourceSwitchID == switchID, sourceSaveID == request else { return }
        guard try await sourceStore.load() == selection else { return }
        guard sourceSwitchID == switchID else { return }
        navigate(.library)
        initializeLibrarySource()
        if let itemID { pendingOverviewItem = (selection, itemID, sourceSwitchID, returnTo) }
      } catch { if sourceSwitchID == switchID { sourceError = error.localizedDescription } }
    }
  }
  func reloadPluginCatalog() async {
    let attempt = UUID(); pluginCatalogGeneration = attempt
    do {
      let developer = CommandLine.arguments.contains("--developer-mode")
      let bundled = try PluginCatalog.load(root: PluginClient.root, developerMode: developer)
      let examples = Bundle.main.resourceURL!.appendingPathComponent("ExamplePlugins")
      if FileManager.default.fileExists(atPath:examples.path) {
        let source=(try? PluginSourceServices.configuration.get())?.first
        try await PluginClient.packages.installExamplesOnce(from:examples,origin:source.map { PluginInstallationOrigin(kind:"bundled",source:$0) })
      }
      let installed = try await PluginClient.packages.catalog(developerMode: developer)
      guard pluginCatalogGeneration == attempt else { return }
      plugins = bundled.plugins + installed.plugins
      pluginIssues = bundled.issues + installed.issues
      if let id = activePlugin?.id { activePlugin = plugins.first { $0.id == id } }
      rebuildFocus()
    } catch { if pluginCatalogGeneration == attempt { pluginIssues = [error.localizedDescription] } }
  }
  private func openSavedContent(_ context: PlaybackHistoryContext, shelf: SavedShelf) {
    let attempt = UUID(); historyOpenID = attempt
    let destination = SavedContentReturn(shelf: shelf, id: context.id)
    Task {
      do {
        guard historyOpenID == attempt, section == .home, detail == nil, hasSavedContent(context.id, shelf: shelf) else { return }
        if let selection = context.librarySource {
          let active = currentSMBProfile.map { LibrarySourceSelection(smbProfileID: $0.id) } ?? LibrarySourceSelection(path: mediaRoot)
          let same = active.path == selection.path && active.smbProfileID == selection.smbProfileID
          var reusable = same
          if same, let profile = currentSMBProfile { reusable = try await smb.profileStore.load().contains(profile) }
          let saved = try await savedSources.store.load().first { $0.matches(selection) }
          guard historyOpenID == attempt, section == .home, detail == nil, !keyboardVisible,
            continueWatching.menuID == nil, watchlist.menuID == nil, hasSavedContent(context.id, shelf: shelf) else { return }
          if reusable, let item = library.first(where: { $0.id == context.mediaID }) {
            navigate(.library); selectContent(item); savedContentReturn = destination
          } else if let saved { selectSavedSource(selection, title: saved.title, opening: context.mediaID, returnTo: destination) }
          else { notice = "此条目的影片来源已移除。可重新添加来源，或从片单移除此卡片。" }
        } else {
          guard historyOpenID == attempt, section == .home, hasSavedContent(context.id, shelf: shelf),
            let plugin = plugins.first(where: { $0.id == context.sourceID }), plugin.isAvailable,
            plugin.manifest.capabilities.contains(shelf.capability), plugin.manifest.capabilities.contains("resolve") else {
            notice = "此内容模块已移除、停用或不再支持保存的条目。"; return
          }
          openModule(plugin, initialDetail: MediaItem(id: context.mediaID, title: context.title, subtitle: context.subtitle,
            poster: savedContentPoster(context, capability: shelf.capability), source: plugin.id,
            reference: context.reference, collectionReference: context.collectionReference))
          savedContentReturn = destination
        }
      } catch { if historyOpenID == attempt { notice = "无法打开保存的内容：" + error.localizedDescription } }
    }
  }
  func quiescePlugin(_ id: String) {
    PluginClient.cancel(pluginID: id)
    externalApp.cancel(pluginID:id)
    NativeLibrary.shared.release(pluginID:id)
    if login.plugin?.id == id { login.close(reload: false) }
    let opened = section == .bilibili && activePlugin?.id == id
    if playbackSourceID == id || (opened && preparingPlayback) { stopPlayback() }
    if opened {
      loadTask?.cancel(); moduleGeneration = UUID(); playbackRequestID = UUID()
      loading = false; navigate(.extensions)
    }
  }
  private func choosePluginUsingSystemPanel() {
    let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
    panel.message = "选择包含 manifest.json 与 plugin.js 的插件文件夹"
    panel.begin { [weak self] result in if result == .OK, let directory = panel.url { self?.pluginManager.prepare(directory) } }
  }
  func presentLibraryOverview(reload: Bool = true) {
    overviewOpenID = UUID()
    pendingOverviewItem = nil
    sourceSwitchID = UUID()
    let current = currentSMBProfile.map { LibrarySourceSelection(smbProfileID: $0.id) }
      ?? (mediaRoot.isEmpty ? nil : LibrarySourceSelection(path: mediaRoot))
    let store = LibraryOverviewStore(sources: savedSources.store, local: libraryIndex,
      nas: smbLibraryIndex, profiles: smb.profileStore)
    libraryOverview.present(store: store, remember: savedSources.store, current: current,
      title: currentSMBProfile?.address ?? URL(fileURLWithPath: mediaRoot).lastPathComponent.nonEmptySourceTitle,
      matches: metadataRecords, reload: reload)
  }
  private func openOverviewSource(_ source: SavedLibrarySource, itemID: String?) {
    let overview = libraryOverview
    let attempt = UUID(); overviewOpenID = attempt
    Task {
      do {
        let present = try await savedSources.store.load().contains(source)
        guard overviewOpenID == attempt, overview.isPresented else { return }
        guard present else {
          notice = "此来源已发生变化，请刷新资料库总览。"; return
        }
        let active = currentSMBProfile.map { LibrarySourceSelection(smbProfileID: $0.id) }
          ?? LibrarySourceSelection(path: mediaRoot)
        var reuseCurrent = source.matches(active)
        if reuseCurrent, let id = source.smbProfileID {
          let latest = try await smb.profileStore.load().first { $0.id == id }
          guard overviewOpenID == attempt, overview.isPresented else { return }
          reuseCurrent = latest != nil && latest == currentSMBProfile
        }
        let selected = itemID.flatMap { id in (libraryCatalog.root + library).first { $0.id == id } }
        if reuseCurrent, itemID == nil || selected != nil {
          overview.close()
          navigate(.library)
          if let selected { selectContent(selected) }
          returnToOverview = true
          return
        }
        overview.close()
        selectSavedSource(source.selection, title: source.title, opening: itemID)
        returnToOverview = true
      } catch { if overviewOpenID == attempt, overview.isPresented { notice = "无法打开来源：" + error.localizedDescription } }
    }
  }
  func reconnectSMB() {
    if let profile = currentSMBProfile { smb.present(profileID: profile.id) }
    else if !currentSMBAddress.isEmpty { smb.present(); smb.newConnection(); smb.address = currentSMBAddress }
  }
  func handleNetworkPath(reachable: Bool) {
    switch networkRecovery.update(reachable: reachable) {
    case .none: return
    case .offline(let id):
      guard let profile = currentSMBProfile, profile.id == id, currentSMBBoundary != nil else { return }
      let namespace = try? SMBMediaIdentity.namespace(profile)
      let ownsPlayback = playbackSourceID == "local" && namespace.map { currentMediaID?.hasPrefix($0 + "\nfile:") == true } == true
      let resume = ownsPlayback && !paused ? currentMediaID : nil
      if ownsPlayback { stopPlayback() }
      if let resume { pendingSMBPlayback = PendingSMBPlayback(id: resume, fromBeginning: false) }
      libraryCommitTask?.cancel(); libraryScanWorker?.cancel(); libraryScanTimeout?.cancel()
      let attempt = UUID(); libraryScanID = attempt
      currentSMBBoundary = nil; mediaRoot = ""; libraryRefreshing = false
      let old = rawLibrary.map { original -> MediaItem in
        var item = original; item.url = nil; item.localMetadata?.sourceReachable = false
        if item.poster.flatMap(URL.init(string:))?.isFileURL == true { item.poster = nil }
        if item.localMetadata?.seriesPoster.flatMap(URL.init(string:))?.isFileURL == true { item.localMetadata?.seriesPoster = nil }
        return item
      }
      applyLibraryItems(old, preservingPosition: true)
      libraryStatus = profile.allowsAutomaticReconnect ? L("网络已断开；保留缓存，恢复后尝试一次重连。") : L("网络已断开；保留缓存，可手动重新连接。")
      libraryNeedsAttention = true
      Task {
        do {
          if let snapshot = try await smbLibraryIndex.load(profile: profile) {
            guard libraryScanID == attempt else { return }
            applyLibraryItems(snapshot.offlineItems(), preservingPosition: true)
          }
        } catch { if libraryScanID == attempt { libraryIndexError = error.localizedDescription } }
        await releaseInactiveSMBShares()
      }
    case .reconnect(let id):
      guard let profile = currentSMBProfile, profile.id == id, needsSMBReconnect,
        !keyboardVisible, !login.isPresented, !sourceSetup.isPresented, !savedSources.isPresented, !smb.isPresented,
        !playbackPresented && !preparingPlayback else { networkRecovery.failed(); return }
      libraryStatus = L("网络已恢复，正在尝试重新连接 NAS")
      smb.reconnectAutomatically(expected: profile)
    }
  }
  func continueWithoutLocalSource(destination: Section) {
    if sourceNeedsSetup {
      sourceNeedsSetup = false
      libraryScanID = UUID()
      libraryRefreshing = false
      mediaRoot = ""
      persistSourceSelection(LibrarySourceSelection(path: nil))
    }
    sourceSetup.close()
    navigate(destination)
  }
  private func persistSourceSelection(_ selection: LibrarySourceSelection, title: String? = nil) {
    let previous = sourceSaveTask
    let store = sourceStore
    let sources = savedSources.store
    let sourceTitle = title ?? selection.path.map { URL(fileURLWithPath: $0).lastPathComponent.nonEmptySourceTitle } ?? "NAS"
    let request = UUID()
    sourceSaveID = request
    savingSource = true
    sourceSaveTask = Task {
      await previous?.value
      do {
        try await store.save(selection)
        if sourceSaveID == request { sourceError = nil }
        if selection.path != nil || selection.smbProfileID != nil {
          do { _ = try await sources.remember(selection, title: sourceTitle) }
          catch { if sourceSaveID == request { sourceError = "当前来源已保存，但来源清单未更新：" + error.localizedDescription } }
        }
      } catch {
        if sourceSaveID == request { sourceError = "本次来源未能保存：" + error.localizedDescription }
      }
      if sourceSaveID == request { savingSource = false }
    }
  }
  func waitForSourceSave() async { await sourceSaveTask?.value }
  func presentLibraryBrowse() {
    guard section == .library, libraryPath.isEmpty else { return }
    libraryBrowser.present(libraryBrowseOptions)
  }
  func applyLibraryBrowse(_ options: LibraryBrowseOptions) {
    let offset = mediaFocusOffset
    let index = (focus.row - offset) * gridColumns + focus.column
    let selected = focus.row >= offset && visibleItems.indices.contains(index) ? visibleItems[index].id : nil
    libraryBrowseOptions = options; rootBrowseCache = nil
    if !CommandLine.arguments.contains("--ui-smoke") {
      UserDefaults.standard.set(options.kind.rawValue, forKey: "mtv.library.kind")
      UserDefaults.standard.set(options.order.rawValue, forKey: "mtv.library.order")
    }
    rebuildFocus()
    if let selected, let location = visibleItems.firstIndex(where: { $0.id == selected }) {
      focus.select(row: offset + location / gridColumns, column: location % gridColumns)
    } else if !visibleItems.isEmpty { focus.select(row: offset, column: 0) }
    else { focus.select(row: 1, column: libraryBrowseColumn) }
  }
  func rebuildFocus(reset: Bool = false) {
    let position = (focus.row, focus.column)
    switch section {
    case .home:
      var rows: [Int] = [5, 1, homePlugins.count + 2]
      if !continueWatching.entries.isEmpty { rows.append(continueWatching.entries.count) }
      if !watchlist.entries.isEmpty { rows.append(watchlist.entries.count) }
      rows.append(contentsOf: mediaRows.map(\.count))
      focus.rows = rows
    case .library: focus.rows = [5, (libraryPath.isEmpty ? 4 : 3) + (needsSMBReconnect ? 1 : 0)] + mediaRows.map(\.count)
    case .bilibili:
      var rows: [Int] = [5]
      let actionColumns: Int = (activePlugin?.manifest.authentication == nil ? 1 : 2) + (moduleSupportsLookup ? 1 : 0)
      rows.append(actionColumns)
      if hasBilibiliTabs { rows.append(BilibiliChannel.allCases.count) }
      rows.append(contentsOf: mediaRows.map(\.count))
      if moduleHasFooter { rows.append(1) }
      focus.rows = rows
    case .extensions: focus.rows = [5, plugins.count + 1]
    case .settings: focus.rows = [navigationItemCount] + TVSetting.groups.map(\.count)
    }
    focus.rows[0] = navigationItemCount
    focus.select(
      row: reset ? 0 : position.0,
      column: reset ? (navigationTabIndex) : position.1)
  }
  func restoreLibraryFromIndex() {
    guard !mediaRoot.isEmpty else { libraryRefreshing = false; return }
    let attempt = UUID()
    libraryScanID = attempt
    libraryRefreshing = true
    let root = URL(fileURLWithPath: mediaRoot, isDirectory: true)
    let index = libraryIndex
    Task {
      do {
        if let snapshot = try await index.load(root: root) {
          guard libraryScanID == attempt else { return }
          scanIncremental = snapshot.incrementalState; scanIncrementalContext = root.path
          applyLibraryItems(snapshot.items)
          libraryIndexedAt = snapshot.scannedAt
          libraryStatus = L("已显示上次索引，正在刷新")
          launchLog.notice("Library index restored; entries=\(snapshot.items.count)")
        }
      } catch {
        guard libraryScanID == attempt else { return }
        libraryIndexError = error.localizedDescription
      }
      guard libraryScanID == attempt else { return }
      scanLibrary(showFailure: false)
    }
  }
  func scanLibrary(showFailure: Bool = true, limit: Int = LibraryScanner.defaultLimit, forceFull: Bool = false) {
    if needsSMBReconnect { reconnectSMB(); return }
    guard !mediaRoot.isEmpty else { presentSourceSetup(); return }
    let verifiedShare: MountedSMBShare?
    do { verifiedShare = try currentValidatedSMBShare(currentSMBBoundary) }
    catch { markSMBMountUnavailable(error); if showFailure { notice = error.localizedDescription }; return }
    libraryCommitTask?.cancel()
    libraryScanWorker?.cancel()
    libraryScanTimeout?.cancel()
    libraryRefreshing = true
    libraryNeedsAttention = false
    let scanID = UUID()
    libraryScanID = scanID
    let root = URL(fileURLWithPath: mediaRoot, isDirectory: true)
    let boundary = currentSMBBoundary
    let profile = currentSMBProfile
    let context = profile.flatMap { try? SMBMediaIdentity.namespace($0) }.map { $0 + "\n" + root.path } ?? root.path
    let priorState = scanIncrementalContext == context ? scanIncremental : nil
    let previous = !forceFull ? priorState : nil
    let previousItems = rawLibrary
    let index = libraryIndex
    let smbIndex = smbLibraryIndex
    let startedAt = Date()
    libraryScanObservation = LibraryScanObservation(id: scanID, root: root.path, startedAt: startedAt.timeIntervalSince1970)
    libraryStatus = rawLibrary.isEmpty ? L("正在扫描影片") : L("正在刷新，现有影片仍可浏览")
    let progress: @Sendable (Int) -> Void = { [weak self] count in
      guard let self else { return }
      Task { @MainActor [weak self] in
        guard let self, self.libraryScanID == scanID, self.libraryRefreshing,
          self.libraryScanWorker != nil else { return }
        self.libraryStatus = L("正在扫描，已识别 \(count) 个影片文件；现有影片仍可浏览")
      }
    }
    let companionSources = savedSources.store
    let worker = Task.detached(priority: .utility) {
      func scan() throws -> LibraryScanResult { try LibraryScanner.scanResult(root: root, limit: limit, allowedResolvedRoot: boundary, previous: previous, progress: progress) }
      let result: LibraryScanResult
      if let verifiedShare { result = try verifiedShare.withCurrentMount(scan) }
      else { result = try scan() }
      if let boundary, let profile { return try result.withSMBIdentity(profile: profile, mount: boundary) }
      if boundary == nil {
        var companions: [MediaItem] = []
        for entry in (try? await companionSources.load()) ?? [] {
          try Task.checkCancellation()
          guard companions.count < 10_000, let path = entry.path, path != root.path else { continue }
          if let snapshot = try? await index.load(root: URL(fileURLWithPath: path)) { companions += snapshot.items.prefix(10_000 - companions.count) }
        }
        return LibraryLinkedMetadata.apply(result, companions: companions, root: root)
      }
      return result
    }
    libraryScanWorker = worker
    libraryScanTimeout = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(30)) } catch { return }
      guard let self, self.libraryScanID == scanID else { return }
      worker.cancel()
      self.libraryScanObservation?.phase = "timeout"
      self.libraryScanObservation?.completedAt = Date().timeIntervalSince1970
      self.libraryScanID = UUID()
      self.libraryRefreshing = false
      self.libraryStatus = L("扫描超时；保留已有索引，可检查磁盘后重新扫描")
      if self.currentSMBProfile != nil { self.networkRecovery.failed() }
      self.libraryNeedsAttention = true
    }
    libraryCommitTask = Task {
      do {
        let result = try await worker.value
        try Task.checkCancellation()
        guard libraryScanID == scanID else { return }
        try verifiedShare?.validateCurrentMount()
        libraryScanWorker = nil
        libraryScanObservation?.phase = result.limited ? "limited" : "readComplete"
        libraryScanObservation?.entries = result.items.count
        libraryScanObservation?.unavailable = result.unavailableCount
        libraryScanObservation?.limited = result.limited
        launchLog.notice("Library scan observed; entries=\(result.items.count) unavailable=\(result.unavailableCount) limited=\(result.limited)")
        libraryScanTimeout?.cancel()
        if result.limited {
          if rawLibrary.isEmpty { applyLibraryItems(result.items) }
          libraryStatus = L("扫描超过 \(limit) 个文件，未替换索引；请选择更小的影片目录")
          libraryNeedsAttention = true
        } else {
          scanIncremental = result.incremental; scanIncrementalContext = context
          libraryReusedCount = result.reusedCount; libraryNFOReadCount = result.nfoReadCount
          launchLog.notice("Incremental scan; reused=\(result.reusedCount) nfoReads=\(result.nfoReadCount) full=\(forceFull)")
          let catalogItems = result.catalogItems(preserving: rawLibrary)
          ArtworkRefresh.shared.invalidate(LibraryArtworkChanges.changed(previous: priorState, current: result.incremental,
            oldItems: rawLibrary, newItems: catalogItems, force: forceFull))
          let retainedMetadata = result.metadataReadFailureIDs.intersection(Set(rawLibrary.map(\.id))).count
          libraryMetadataFailureCount = result.metadataReadFailureIDs.count
          applyLibraryItems(catalogItems, preservingPosition: true)
          libraryMaintenance.enrich(model: self)
          if let pending = pendingOverviewItem, pending.generation == sourceSwitchID {
            pendingOverviewItem = nil
            notice = "所选内容已不在此来源中，请返回资料库总览刷新。"
          }
          libraryStatus = result.unavailableCount == 0
            ? L("已刷新 \(catalogItems.count) 个影片文件")
            : L("已更新目录，\(result.unavailableCount) 个片源离线；已保留条目，请检查磁盘或链接")
          if !result.metadataReadFailureIDs.isEmpty {
            libraryStatus += L("；\(result.metadataReadFailureIDs.count) 项资料读取失败，其中 \(retainedMetadata) 项沿用缓存")
          }
          libraryNeedsAttention = result.unavailableCount > 0 || !result.metadataReadFailureIDs.isEmpty
          if boundary == nil {
            do {
              let saved = try await index.save(items: catalogItems, root: root, scannedAt: startedAt, incremental: result.incremental?.manifest)
              guard libraryScanID == scanID else { return }
              libraryIndexedAt = saved ? startedAt : try await index.load(root: root)?.scannedAt
              libraryIndexError = nil
              launchLog.notice("Library index ready; entries=\(catalogItems.count)")
            } catch {
              guard libraryScanID == scanID else { return }
              libraryIndexError = error.localizedDescription
            }
          } else if let boundary, let profile {
            do {
              guard let verifiedShare else { throw SMBFailure.mountChanged(3) }
              let outcome = try await smbIndex.saveDetailed(catalogItems, profile: profile, mount: boundary, scannedAt: startedAt, verifying: verifiedShare)
              guard libraryScanID == scanID else { return }
              libraryIndexedAt = startedAt; libraryIndexError = nil
              if outcome.artworkSkipped > 0 {
                libraryStatus += L("；\(outcome.artworkSkipped) 张封面未缓存")
                libraryNeedsAttention = true
              }
            } catch {
              guard libraryScanID == scanID else { return }
              if (error as? SMBFailure)?.stage == .mountValidation { throw error }
              libraryIndexError = error.localizedDescription
            }
          }
        }
      } catch {
        if libraryScanID == scanID {
          if (error as? SMBFailure)?.stage == .mountValidation {
            scanIncremental = priorState; scanIncrementalContext = priorState == nil ? nil : context
            applyLibraryItems(previousItems, preservingPosition: true); markSMBMountUnavailable(error)
          }
          libraryScanTimeout?.cancel()
          libraryStatus = L("影片目录暂不可用；保留已有索引")
          if currentSMBProfile != nil { networkRecovery.failed() }
          libraryNeedsAttention = true
          let error = error as NSError
          libraryScanObservation?.phase = "failed"
          libraryScanObservation?.failureDomain = error.domain
          libraryScanObservation?.failureCode = error.code
          launchLog.notice("Library scan failed; domain=\(error.domain, privacy: .public) code=\(error.code)")
          if showFailure { notice = error.localizedDescription }
        }
      }
      if libraryScanID == scanID {
        if libraryScanObservation?.phase == "readComplete" { libraryScanObservation?.phase = "completed" }
        libraryScanObservation?.completedAt = Date().timeIntervalSince1970
        libraryRefreshing = false
        rebuildFocus()
        await releaseInactiveSMBShares()
        if let pending = pendingSMBPlayback {
          pendingSMBPlayback = nil
          if let item = library.first(where: { $0.id == pending.id }) { play(item, fromBeginning: pending.fromBeginning) }
          else { notice = "连接后没有找到刚才的影片，请重新扫描或选择条目" }
        }
      }
    }
  }
  func focusNavigation(at index: Int) {
    guard visibleNavigationTabs.indices.contains(index) else { return }
    let tab = visibleNavigationTabs[index]
    if activeNavigationTab != tab {
      switch tab {
      case .home: navigate(.home)
      case .library: navigate(.library)
      case .bilibili: navigate(.bilibili)
      case .quark:
        guard let plugin = plugins.first(where: { $0.id == "mtv.quark" && $0.isAvailable }) else { return }
        openModule(plugin)
      case .extensions: navigate(.extensions)
      case .settings: navigate(.settings)
      }
    }
    focus.select(row: 0, column: index)
  }
  private func moveMainFocus(dx: Int, dy: Int) {
    if section == .settings, focus.row > 0 {
      moveSettingsFocus(dx: dx, dy: dy); return
    }
    let previousRow = focus.row
    let wasNavigation = focus.row == 0
    if hasBilibiliTabs, wasNavigation, dy > 0 {
      focus.select(row: bilibiliChannelRow, column: 0)
    } else if hasModuleSubnavigation, !hasBilibiliTabs, wasNavigation, dy > 0,
      focus.rows.indices.contains(mediaFocusOffset) {
      focus.select(row: mediaFocusOffset, column: 0)
    } else {
      focus.move(dx: dx, dy: dy)
    }
    if focus.row == 0 {
      // Enter the tab bar on the current tab, rather than on the column of a card below it.
      focusNavigation(at: wasNavigation ? focus.column : (navigationTabIndex))
    } else if hasBilibiliTabs, focus.row == bilibiliChannelRow {
      let index = previousRow == bilibiliChannelRow ? focus.column : (BilibiliChannel.allCases.firstIndex(of: bilibiliChannel) ?? 2)
      selectBilibiliChannel(at: index)
    }
    if section == .bilibili, dy != 0, focus.row == moduleToolbarRow, previousRow != moduleToolbarRow {
      focus.select(row: moduleToolbarRow, column: 0)
    }
    if section == .settings, previousRow == 0, focus.row > 0 {
      settingsSidebarFocus = true; focus.select(row: settingsGroup, column: 0)
    }
    if section == .bilibili, focus.row >= max(mediaFocusOffset, mediaFocusOffset + mediaRows.count - 2) {
      loadMoreModuleIfNeeded()
    }
  }
  func loadMoreModuleIfNeeded() {
    guard section == .bilibili, !foregroundLoading, moduleLoadFailure == nil, let page = moduleNextPage else { return }
    loadModule(action: search.isEmpty ? "browse" : "search", input: ["query": search, "page": page], append: true)
  }
  func selectBilibiliChannel(at index: Int) {
    guard hasBilibiliTabs, BilibiliChannel.allCases.indices.contains(index) else { return }
    let channel = BilibiliChannel.allCases[index]
    let reload = channel != bilibiliChannel || !modulePath.isEmpty || !search.isEmpty
    bilibiliChannel = channel
    if reload {
      modulePath = []; moduleHistory = []; search = ""; detail = nil
      loadModule()
    }
    focus.select(row: bilibiliChannelRow, column: index)
  }
  func navigate(_ value: Section) {
    nativeMedia.close()
    mediaSessionConsent = nil
    libraryBrowser.close()
    historyOpenID = UUID(); savedContentReturn = nil; continueWatching.menuID = nil; watchlist.menuID = nil
    sourceSwitchID = UUID()
    pendingOverviewItem = nil
    libraryOverview.close()
    if value != .library { returnToOverview = false }
    if preparingPlayback { stopPlayback() }
    resumeModuleOnLoginDismiss = false
    login.close(reload: false)
    metadata.close()
    automaticMetadata.close()
    localFolders.close()
    playbackRequestID = UUID()
    if value == .bilibili {
      guard let plugin = plugins.first(where: { $0.id == "mtv.bilibili" }) else {
        notice = "哔哩哔哩插件未安装，详见设置中的插件诊断。"
        return
      }
      openModule(plugin)
      return
    }
    moduleGeneration = UUID()
    loadTask?.cancel()
    moduleLoadFailure = nil
    loading = false
    section = value
    libraryPath = []
    libraryHistory = []
    search = ""
    detail = nil
    notice = nil
    rebuildFocus(reset: true)
  }
  func openModule(_ plugin: PluginRecord, initialDetail: MediaItem? = nil) {
    nativeMedia.close()
    if plugin.manifest.applicationLaunch != nil, initialDetail == nil {
      notice=nil
      externalApp.launch(plugin)
      if externalApp.phase == "not-installed" { notice = externalApp.message }
      return
    }
    if plugin.manifest.nativeLibraries != nil {
      do {
        if plugin.manifest.nativeLibraries?.contains(where: { ["photos","pictures"].contains($0) }) == true {
          let share = try currentValidatedSMBShare(currentSMBBoundary)
          let roots = mediaRoot.isEmpty ? FileManager.default.urls(for:.picturesDirectory,in:.userDomainMask) : [URL(fileURLWithPath:mediaRoot)]
          try NativeLibrary.shared.configure(pluginID:plugin.id,roots:roots,share:share)
        } else { try NativeLibrary.shared.configure(pluginID:plugin.id,roots:[]) }
      } catch {
        NativeLibrary.shared.markUnavailable(pluginID:plugin.id,message:L("The selected media source is unavailable. Reconnect it in Settings."))
      }
    }
    mediaSessionConsent = nil
    if let initialDetail, initialDetail.source != plugin.id || initialDetail.isFolder || initialDetail.isLibraryCollection {
      notice = "保存的内容不属于当前模块"; return
    }
    resumeModuleOnLoginDismiss = false
    login.close(reload: false)
    playbackRequestID = UUID()
    guard plugin.isAvailable else {
      notice = L("\(plugin.title) · 开发中")
      return
    }
    activePlugin = plugin
    if plugin.id == "mtv.bilibili" { bilibiliChannel = .home }
    moduleLoadFailure = nil
    moduleNeedsLogin = false
    modulePath = []
    moduleHistory = []
    if moduleSessionAccess == .stored { login.refresh(plugin) }
    section = .bilibili
    search = ""
    online = []
    moduleNextPage = nil
    detail = nil
    notice = nil
    rebuildFocus(reset: true)
    if let initialDetail {
      moduleGeneration = UUID(); loadTask?.cancel(); loadTask = nil; loading = false
      selectContent(initialDetail)
    } else { loadModule() }
  }
  func loadModule(action: String = "browse", input: [String: String] = [:], append: Bool = false) {
    guard let plugin = activePlugin else { return }
    var input = input
    if plugin.id == "mtv.bilibili", action == "browse" { input["channel"] = bilibiliChannel.rawValue }
    if let reference = modulePath.last?.reference { input["folder"] = reference }
    loadTask?.cancel()
    let generation = UUID()
    moduleGeneration = generation
    moduleLoadFailure = nil
    let path = modulePath.compactMap(\.reference)
    let query = search
    let requestedPage = input["page"]
    if !append {
      online = []
      moduleNextPage = nil
      moduleNeedsLogin = false
    }
    loading = true
    loadTask = Task {
      defer {
        if moduleGeneration == generation {
          loading = false
          rebuildFocus()
          if moduleLoadFailure != nil, !keyboardVisible, !login.isPresented, detail == nil {
            focus.select(row: mediaFocusOffset + mediaRows.count, column: 0)
          }
        }
      }
      do {
        let data = try await PluginClient.execute(
          plugin, action: action, input: input, sessionAccess: moduleSessionAccess)
        guard !Task.isCancelled, moduleGeneration == generation else { return }
        let page = try JSONDecoder().decode(PluginPage.self, from: data)
        guard page.requiresLogin != true || plugin.manifest.authentication != nil else {
          throw MTVError.message("插件要求登录但未声明账号支持")
        }
        guard page.requiresLogin != true || (page.items.isEmpty && page.next == nil) else {
          throw MTVError.message("登录提示页不能同时包含内容或分页")
        }
        moduleNeedsLogin = page.requiresLogin == true
        var normalized = try PluginContentValidator.normalize(page.items, manifest: plugin.manifest)
        for index in normalized.indices where normalized[index].kind == .photo {
          let reference = normalized[index].reference ?? ""
          if plugin.manifest.nativeLibraries?.contains("photos") == true {
            normalized[index].poster = try await PhotoResources.artwork(owner:plugin.id,reference:reference)
          } else if reference.hasPrefix("quark:"), plugin.manifest.nativeLibraries?.contains("quark-pictures") == true {
            normalized[index].poster = await CloudPhotos.shared.preview(owner:plugin.id,reference:reference)
          } else {
            let url = try NativeLibrary.shared.asset(pluginID:plugin.id,services:plugin.manifest.nativeLibraries ?? [],reference:reference,kind:.photo)
            normalized[index].poster = url.absoluteString
          }
        }
        for index in normalized.indices {
          if let artwork = normalized[index].artworkReference, plugin.manifest.nativeLibraries?.contains("music") == true {
            normalized[index].poster = await MusicArtwork.shared.reference(owner:plugin.id,track:artwork)
          }
        }
        guard !Task.isCancelled, moduleGeneration == generation else { return }
        let previousIDs = Set(online.map(\.id))
        if let next = page.next, next == requestedPage { throw MTVError.message("这一页没有前进，已停止重复加载，请稍后重试") }
        if action == "lookup" {
          guard page.requiresLogin != true, page.next == nil, normalized.count == 1, !normalized[0].isFolder else { throw MTVError.message("模块没有返回唯一可打开的视频") }
        }
        if page.requiresLogin == true {
          online = []
        } else if append {
          let existing = Set(online.map(\.id))
          online += normalized.filter { !existing.contains($0.id) }
        } else {
          online = normalized
        }
        moduleNextPage = page.next
        // A filtered cloud-drive page can contain only documents. Its advancing
        // cursor must survive so a later page's films are not silently omitted.
        if append, !PluginPagination.mayAdvance(returnedIDs: normalized.map(\.id), knownIDs: previousIDs) { moduleNextPage = nil }
        if action == "lookup", let item = normalized.first { selectContent(item) }
      } catch {
        guard !Task.isCancelled, moduleGeneration == generation else { return }
        moduleLoadFailure = ModuleLoadFailure(pluginID: plugin.id, action: action, input: input,
          append: append, path: path, query: query, message: String(error.localizedDescription.prefix(600)))
      }
    }
  }
  func retryModuleLoad() {
    guard let failure = moduleLoadFailure, !foregroundLoading, section == .bilibili,
      activePlugin?.id == failure.pluginID, modulePath.compactMap(\.reference) == failure.path
    else { return }
    search = failure.query
    loadModule(action: failure.action, input: failure.input, append: failure.append)
  }
  func openNativeMedia(_ item: MediaItem) {
    guard let plugin = activePlugin, plugin.id == item.source, let reference = item.reference, let kind = item.kind else { return }
    if kind == .photo, plugin.manifest.nativeLibraries?.contains("photos") == true {
      stopPlayback()
      let requestID = playbackRequestID
      nativeMedia.openRemote(item,read:{ try await PhotoResources.read(owner:plugin.id,reference:reference) },failure:{ [weak self] error in
        guard let self, self.activePlugin?.id == plugin.id, self.playbackRequestID == requestID else { return }
        if case PhotoResources.Failure.mediaApprovalRequired(let owner, let host) = error {
          self.nativeMedia.close()
          self.mediaSessionConsent = MediaSessionConsent(requestID:requestID,pluginID:owner,host:host,item:item,fromBeginning:false)
          self.mediaSessionConsentSelection = 1
        }
      })
      let peers = online.filter { $0.kind == .photo }
      nativeMedia.onStep = { [weak self] step in
        guard let self, let current = self.nativeMedia.item, let index = peers.firstIndex(where:{$0.id==current.id}), peers.indices.contains(index+step) else { return }
        self.openNativeMedia(peers[index+step])
      }
      return
    }
    if kind == .photo, reference.hasPrefix("quark:"), plugin.manifest.nativeLibraries?.contains("quark-pictures") == true {
      stopPlayback()
      let requestID = playbackRequestID
      nativeMedia.openRemote(item,read:{ try await CloudPhotos.shared.data(owner:plugin.id,reference:reference) },failure:{ [weak self] error in
        guard let self, self.activePlugin?.id == plugin.id, self.playbackRequestID == requestID else { return }
        if case CloudPhotoFailure.mediaApprovalRequired(let host) = error {
          self.nativeMedia.close()
          self.mediaSessionConsent = MediaSessionConsent(requestID:requestID,pluginID:"mtv.quark",host:host,item:item,fromBeginning:false)
          self.mediaSessionConsentSelection = 1
        }
      })
      let peers = online.filter { $0.kind == .photo }
      nativeMedia.onStep = { [weak self] step in
        guard let self, let current = self.nativeMedia.item, let index = peers.firstIndex(where:{$0.id==current.id}), peers.indices.contains(index+step) else { return }
        self.openNativeMedia(peers[index+step])
      }
      return
    }
    do {
      let url = try NativeLibrary.shared.asset(pluginID:plugin.id,services:plugin.manifest.nativeLibraries ?? [],reference:reference,kind:kind)
      let peers = online.filter { $0.kind == kind }
      stopPlayback()
      nativeMedia.onStep = { [weak self] step in
        guard let self, let current = self.nativeMedia.item, let index = peers.firstIndex(where:{$0.id==current.id}), peers.indices.contains(index+step) else { return }
        self.openNativeMedia(peers[index+step])
      }
      nativeMedia.open(item,url:url,access:NativeLibrary.shared.fileAccess(pluginID:plugin.id,reference:reference,url:url))
    } catch { notice = error.localizedDescription }
  }
  func activateCard(_ item: MediaItem) {
    if item.kind == .photo || item.kind == .audio { openNativeMedia(item); return }
    if var episode = libraryCatalog.singlePlayableEpisode(of: item) {
      episode.title = item.title
      episode.poster = episode.poster ?? item.poster
      detail = nil
      play(episode)
      return
    }
    if item.isFolder || item.isLibraryCollection { selectContent(item) }
    else { detail = nil; play(item) }
  }
  func selectContent(_ item: MediaItem) {
    let previousSavedReturn = savedContentReturn
    let previousSavedDetail = savedContentReturn == nil ? nil : detail
    historyOpenID = UUID(); savedContentReturn = nil
    if item.isLibraryCollection {
      guard item.source == "local", libraryCatalog.children[item.id] != nil,
        section == .library || section == .home
      else { return }
      libraryHistory.append(
        LibraryPosition(section: section, query: search, row: focus.row, column: focus.column))
      libraryPath.append(item)
      section = .library
      search = ""
      detail = nil
      rebuildFocus()
      focus.select(row: 1, column: 0)
      return
    }
    guard item.isFolder else {
      detail = item
      detailAction = 0
      return
    }
    guard section == .bilibili, let plugin = activePlugin, item.source == plugin.id,
      plugin.manifest.capabilities.contains("folders"), let reference = item.reference,
      !reference.isEmpty, modulePath.count < 64,
      !modulePath.contains(where: { $0.reference == reference })
    else {
      notice = "无法打开此目录，或目录层级过深"
      return
    }
    moduleHistory.append(
      ModuleSnapshot(
        items: online, next: moduleNextPage, query: search,
        failure: moduleLoadFailure,
        row: focus.row, column: focus.column,
        savedDetail: previousSavedDetail, savedReturn: previousSavedReturn))
    modulePath.append(item)
    search = ""
    detail = nil
    focus.select(row: 1, column: 0)
    loadModule()
  }
  func canOpenCollection(_ item: MediaItem) -> Bool {
    section == .bilibili && item.source == activePlugin?.id && !item.isFolder
      && item.collectionReference != nil && activePlugin?.manifest.capabilities.contains("folders") == true
  }
  var detailHasSecondaryAction: Bool {
    guard let detail else { return false }
    return detailControls(for: detail).count > 2
  }
  enum DetailControl: Hashable { case play, restart, metadata, collection, watchlist, close }
  func resumeRecord(for item: MediaItem) -> PlaybackResumeRecord? {
    guard !item.isFolder, !item.isLibraryCollection else { return nil }
    return resumeStore.record(for: item.id, source: item.source)
  }
  func detailControls(for item: MediaItem) -> [DetailControl] {
    var controls: [DetailControl] = [.play]
    if (resumeRecord(for: item)?.resumablePosition ?? 0) > 0 { controls.append(.restart) }
    if item.source == "local" { controls.append(.metadata) }
    else if canOpenCollection(item) { controls.append(.collection) }
    if canWatchlist(item) { controls.append(.watchlist) }
    return controls + [.close]
  }
  func performDetailControl(_ control: DetailControl, item: MediaItem) {
    switch control {
    case .play: play(item)
    case .restart: play(item, fromBeginning: true)
    case .metadata: presentMetadata(for: item)
    case .collection: openCollection(item)
    case .watchlist: toggleWatchlist(item)
    case .close: closeHistoryDetail()
    }
  }
  func openCollection(_ item: MediaItem) {
    guard canOpenCollection(item), let reference = item.collectionReference else { return }
    playbackRequestID = UUID()
    var collection = item
    collection.id = "mtv:parts:" + item.id
    collection.reference = reference
    collection.collectionReference = nil
    collection.kind = .folder
    selectContent(collection)
  }
  func applyLibraryItems(_ items: [MediaItem], preservingPosition: Bool = false) {
    let path = preservingPosition ? libraryPath.map(\.id) : []
    let history = libraryHistory
    let opened = preservingPosition && detail?.source == "local" ? detail?.id : nil
    let offset = mediaFocusOffset
    let position = (focus.row - offset) * gridColumns + focus.column
    let selected = preservingPosition && (section == .home || section == .library)
      && focus.row >= offset && visibleItems.indices.contains(position)
      ? visibleItems[position].id : nil
    rawLibrary = items
    do {
      metadataRecords = try metadataStore.load()
      metadataCacheError = nil
    } catch {
      metadataCacheError = error.localizedDescription
      metadataRecords = [:]
      notice = "MacTV 匹配缓存未能读取，当前显示原始信息：\(error.localizedDescription)"
    }
    library = MetadataStore.apply(metadataRecords, to: items, localizedSeries: localizedSeries)
    loadLocalizedSeries()
    libraryCatalog = LibraryCatalog.build(library)
    rootBrowseCache = nil
    libraryPath = []
    libraryHistory = []
    if preservingPosition {
      libraryPath = libraryCatalog.restoringDisplayedPath(path)
      libraryHistory = Array(history.prefix(libraryPath.count))
      if let opened { detail = library.first { $0.id == opened } }
    }
    rebuildFocus()
    if let selected, let index = visibleItems.firstIndex(where: { $0.id == selected }) {
      focus.select(row: offset + index / gridColumns, column: index % gridColumns)
    }
    if playbackPresented { refreshNextEpisodePlan() }
    if let pending = pendingOverviewItem, pending.generation == sourceSwitchID {
      let selectedSource = currentSMBProfile.map { LibrarySourceSelection(smbProfileID: $0.id) }
        ?? LibrarySourceSelection(path: mediaRoot)
      if selectedSource == pending.selection,
        let item = (libraryCatalog.root + library).first(where: { $0.id == pending.id }) {
        pendingOverviewItem = nil
        if let destination = pending.returnTo, !hasSavedContent(destination.id, shelf: destination.shelf) { return }
        selectContent(item)
        savedContentReturn = pending.returnTo
      }
    }
  }
  private func loadLocalizedSeries() {
    guard MetadataStore.prefersChinese, metadata.tokenConfigured, seriesLocalizationTask == nil,
      !CommandLine.arguments.contains("--ui-smoke") else { return }
    let identifiers = Set(library.compactMap { item -> Int? in
      guard let info = item.localMetadata, info.episode != nil,
        !MetadataStore.containsChinese(info.seriesTitle ?? "") || !MetadataStore.containsChinese(info.seriesOverview ?? ""),
        let attribution = item.metadataAttribution, attribution.hasPrefix("https://www.tvmaze.com/shows/") else { return nil }
      return Int(attribution.split(separator: "/").last ?? "")
    })
    let pending = identifiers.sorted().filter { id in
      localizedSeries[id] == nil && Date().timeIntervalSince(seriesLocalizationAttempts[id] ?? .distantPast) > 900
    }
    guard !pending.isEmpty else { return }
    let configuredToken = metadata.tmdbToken
    let tokenStore = metadata.tokenStore
    seriesLocalizationTask = Task { [weak self] in
      guard let self else { return }
      defer { self.seriesLocalizationTask = nil }
      guard let token = configuredToken ?? (try? tokenStore.load()) else { return }
      let client = MetadataClient()
      var changed = false
      for id in pending {
        guard !Task.isCancelled else { return }
        self.seriesLocalizationAttempts[id] = Date()
        if let result = try? await client.localizedSeries(tvmazeID: id, token: token) {
          self.localizedSeries[id] = result
          changed = true
        }
      }
      if changed { self.applyLibraryItems(self.rawLibrary, preservingPosition: true) }
    }
  }
  func applyMetadata(item: MediaItem, candidate: MetadataCandidate?) throws {
    guard item.source == "local", item.kind != .season,
      item.localMetadata?.episode == nil || item.kind == .series
    else { throw MTVError.message("请为影片或整个系列匹配信息") }
    if let candidate, candidate.kind != (item.kind == .series ? .series : .movie) {
      throw MTVError.message("元数据类型与所选影片不一致")
    }
    let path = libraryPath.map(\.id)
    let history = libraryHistory
    let opened = detail?.id
    metadataRecords = try metadataStore.set(targetID: item.id, candidate: candidate)
    let source = rawLibrary
    applyLibraryItems(source)
    libraryHistory = history
    libraryPath = libraryCatalog.restoringDisplayedPath(path)
    if let opened { detail = library.first { $0.id == opened } }
    rebuildFocus()
  }
  func presentMetadata(for item: MediaItem) {
    if item.kind == .versions, let first = libraryCatalog.children[item.id]?.first { presentMetadata(for: first); return }
    if item.kind == .extras { notice = "请先选择要匹配资料的影片。"; return }
    if let identity = LibraryCatalog.seriesIdentity(item),
      let series = libraryCatalog.root.first(where: { $0.id == "mtv:series:" + identity })
    {
      metadata.present(series)
    } else {
      metadata.present(item)
    }
  }
  func prepareAutomaticMetadata() {
    metadata.close()
    do {
      let matches = try metadataStore.load()
      automaticMetadata.prepare(
        targets: AutomaticMetadata.targets(files: rawLibrary, matches: matches),
        client: metadata.client, tokenStore: metadata.tokenStore, token: metadata.tmdbToken,
        inventory: LibraryInventoryReport(root: URL(fileURLWithPath: mediaRoot), basis: "app-live-catalog", files: rawLibrary, matches: matches))
    } catch { notice = error.localizedDescription }
  }
  func showMetadataToken() {
    savedKeyboardMode = (chinese, uppercase)
    textEntryTarget = .metadataToken
    keyboardDraft = ""
    keyboardSymbols = false
    clearPinyin()
    chinese = false
    uppercase = false
    keyboardFocus = FocusGrid(rows: keyboardRows.map(\.count))
    keyboardVisible = true
  }
  func pasteKeyboardText() {
    guard keyboardVisible, let value = NSPasteboard.general.string(forType: .string),
      value.utf8.count <= 4096
    else { return }
    finishComposition()
    inputText += value
  }
  func showMetadataQuery() {
    savedKeyboardMode = (chinese, uppercase)
    textEntryTarget = .metadataQuery
    keyboardDraft = metadata.query
    keyboardSymbols = false
    clearPinyin()
    uppercase = false
    keyboardFocus = FocusGrid(rows: keyboardRows.map(\.count))
    keyboardVisible = true
  }
  func showOverviewKeyboard() {
    overviewOpenID = UUID()
    savedKeyboardMode = (chinese, uppercase)
    textEntryTarget = .overviewSearch
    keyboardDraft = libraryOverview.query
    keyboardSymbols = false
    clearPinyin(); uppercase = false
    keyboardFocus = FocusGrid(rows: keyboardRows.map(\.count))
    keyboardVisible = true
  }
  func showPluginPath() {
    savedKeyboardMode = (chinese, uppercase); textEntryTarget = .pluginPath
    keyboardDraft = pluginFolders.directory?.path ?? pluginFolders.shortcutURL.path
    keyboardSymbols = false; clearPinyin(); chinese = false; uppercase = false
    keyboardFocus = FocusGrid(rows: keyboardRows.map(\.count)); keyboardVisible = true
  }
  func showPluginSourceInput(reference: Bool) {
    savedKeyboardMode=(chinese,uppercase); textEntryTarget=reference ? .pluginSourceReference:.pluginSourceURL
    keyboardDraft=reference ? (pluginManager.selectedSource?.reference ?? "main") : ""; keyboardSymbols=false; clearPinyin(); chinese=false; uppercase=false
    keyboardFocus=FocusGrid(rows:keyboardRows.map(\.count)); keyboardVisible=true
  }
  func showModuleLookup() {
    guard section == .bilibili, let plugin = activePlugin, moduleSupportsLookup else { return }
    historyOpenID = UUID(); savedContentReturn = nil
    savedKeyboardMode = (chinese, uppercase); textEntryTarget = .moduleReference
    moduleLookupOwner = plugin.id; keyboardDraft = ""; keyboardSymbols = false
    clearPinyin(); chinese = false; uppercase = true
    keyboardFocus = FocusGrid(rows: keyboardRows.map(\.count)); keyboardVisible = true
  }
  func lookupModule(_ reference: String, owner: String) {
    guard section == .bilibili, activePlugin?.id == owner, moduleSupportsLookup else { return }
    modulePath = []; moduleHistory = []; search = ""; detail = nil
    loadModule(action: "lookup", input: ["reference": reference])
  }
  func searchLibraryOverview(_ query: String) {
    libraryOverview.setQuery(query)
    presentLibraryOverview()
  }
  @discardableResult func backLibraryCollection() -> Bool {
    guard section == .library, let parent = libraryHistory.popLast() else { return false }
    libraryPath.removeLast()
    section = parent.section
    search = parent.query
    detail = nil
    rebuildFocus()
    focus.select(row: parent.row, column: parent.column)
    return true
  }
  @discardableResult func backModuleFolder() -> Bool {
    guard section == .bilibili, let parent = moduleHistory.popLast() else { return false }
    loadTask?.cancel()
    moduleGeneration = UUID()
    playbackRequestID = UUID()
    modulePath.removeLast()
    online = parent.items
    moduleNeedsLogin = false
    moduleNextPage = parent.next
    moduleLoadFailure = parent.failure
    search = parent.query
    detail = nil
    loading = false
    rebuildFocus()
    focus.select(row: parent.row, column: parent.column)
    if let savedDetail = parent.savedDetail, let destination = parent.savedReturn {
      if hasSavedContent(destination.id, shelf: destination.shelf) {
        detail = savedDetail; savedContentReturn = destination
        detailAction = detailControls(for: savedDetail).firstIndex(of: .collection) ?? 0
      } else { navigate(.home) }
    }
    return true
  }
  func showKeyboard() {
    historyOpenID = UUID(); savedContentReturn = nil
    if preparingPlayback { stopPlayback() }
    keyboardSymbols = false
    if let savedKeyboardMode { (chinese, uppercase) = savedKeyboardMode }
    savedKeyboardMode = nil
    smb.close()
    textEntryTarget = .search
    keyboardDraft = ""
    login.close(reload: false)
    playbackRequestID = UUID()
    if detail != nil {
      detail = nil
      loading = false
    }
    clearPinyin()
    candidateIndex = 0
    candidateFocus = false
    keyboardFocus = FocusGrid(rows: keyboardRows.map(\.count))
    keyboardVisible = true
  }
  func showSMBTextEntry(_ field: SMBControl) {
    keyboardSymbols = false
    savedKeyboardMode = (chinese, uppercase)
    switch field {
    case .address:
      textEntryTarget = .smbAddress
      keyboardDraft = smb.address
    case .username:
      textEntryTarget = .smbUsername
      keyboardDraft = smb.username
    case .password:
      textEntryTarget = .smbPassword
      keyboardDraft = smb.password
    default: return
    }
    clearPinyin()
    chinese = false
    uppercase = false
    keyboardFocus = FocusGrid(rows: keyboardRows.map(\.count))
    keyboardVisible = true
  }
  func acceptSystemText(_ text: String) {
    guard keyboardVisible, !keyboardSecret else { return }
    inputText = text.components(separatedBy: .newlines).joined(separator: " ")
    clearPinyin(); candidateFocus = false
  }
  func finishTextEntry(commit: Bool) {
    systemTextView?.finishInput(commit: commit)
    if commit {
      switch textEntryTarget {
      case .overviewSearch: searchLibraryOverview(keyboardDraft)
      case .smbAddress: smb.address = keyboardDraft
      case .smbUsername: smb.username = keyboardDraft
      case .smbPassword: smb.password = keyboardDraft
      case .metadataQuery:
        metadata.query = keyboardDraft
        metadata.search()
      case .metadataToken: metadata.saveToken(keyboardDraft)
      case .localPath: localFolders.openAddress(keyboardDraft)
      case .pluginPath: pluginFolders.openAddress(keyboardDraft)
      case .pluginSourceURL: pluginManager.addSource(keyboardDraft)
      case .pluginSourceReference: pluginManager.saveSourceReference(keyboardDraft)
      case .moduleReference:
        if let owner = moduleLookupOwner { lookupModule(keyboardDraft, owner: owner) }
      case .search: break
      }
    }
    keyboardVisible = false
    keyboardDraft = ""
    moduleLookupOwner = nil
    if let savedKeyboardMode { (chinese, uppercase) = savedKeyboardMode }
    savedKeyboardMode = nil
    textEntryTarget = .search
    clearPinyin()
  }
  func pressKey(_ key: String) {
    switch key {
    case "符号":
      finishComposition()
      keyboardSymbols.toggle()
      keyboardFocus = FocusGrid(rows: keyboardRows.map(\.count))
      candidateFocus = false
    case "中/英":
      guard !keyboardSecret else { return }
      finishComposition()
      chinese.toggle()
      candidateFocus = false
    case "大小写":
      finishComposition()
      chinese = false
      uppercase.toggle()
      candidateFocus = false
    case "空格":
      if chinese, !composing.isEmpty { commitCandidate() } else { inputText += " " }
    case "退格": backspace()
    case "清空":
      inputText = ""
      clearPinyin()
    case "听写": requestSystemDictation()
    case "完成":
      systemTextView?.finishInput(commit: true)
      finishComposition()
      if textEntryTarget != .search {
        finishTextEntry(commit: true)
        return
      }
      keyboardVisible = false
      if section == .bilibili, moduleSupportsSearch {
        loadModule(action: search.isEmpty ? "browse" : "search", input: ["query": search])
      }
      rebuildFocus()
    default:
      if chinese && !keyboardSymbols, key == "'" || key.rangeOfCharacter(from: .letters) != nil {
        insertPinyin(key.lowercased())
      } else {
        finishComposition()
        inputText += uppercase ? key.uppercased() : key.lowercased()
      }
    }
  }
  func commitCandidate() {
    if candidateIndex < candidates.count {
      applyPinyin(2, Int32(candidateIndex))
      candidateFocus = !composing.isEmpty
    } else if candidateActions.indices.contains(candidateIndex) {
      applyPinyin(1, candidateActions[candidateIndex] == "上一页" ? 0xff55 : 0xff56)
    } else {
      finishComposition()
    }
  }
  func backspace() {
    if !pinyin.state.input.isEmpty {
      applyPinyin(1, 0xff08)
    } else if !inputText.isEmpty {
      inputText.removeLast()
    }
  }
  private func applyPinyin(_ operation: Int32, _ argument: Int32 = 0) {
    do {
      let result = try pinyin.apply(operation, argument)
      inputText += result.commit
      composing = result.preedit
      candidateIndex = 0
    } catch { notice = error.localizedDescription }
  }
  private func insertPinyin(_ text: String) {
    guard pinyin.ready else {
      applyPinyin(0)
      return
    }
    guard pinyin.state.input.utf8.count + text.utf8.count <= 256 else { return }
    for character in text.utf8 { applyPinyin(1, Int32(character)) }
  }
  private func clearPinyin() {
    if pinyin.ready { _ = try? pinyin.apply(3) }
    composing = ""
    candidateIndex = 0
    candidateFocus = false
  }
  private func finishComposition() {
    guard !pinyin.state.input.isEmpty else { return }
    let raw = pinyin.state.input
    applyPinyin(4)
    // Preserve literal input when the engine cannot commit an unfinished spelling.
    if !pinyin.state.input.isEmpty {
      inputText += raw
      clearPinyin()
    }
    candidateFocus = false
  }
  func handle(_ action: InputAction) {
    handle(action, chromeImportAllowed: true, interactiveLoginAllowed: true)
  }
  func handle(_ action: InputAction, chromeImportAllowed: Bool, interactiveLoginAllowed: Bool) {
    if nativeMedia.isPresented { nativeMedia.handle(action); return }
    if mediaSessionConsent != nil, notice == nil { handleMediaSessionConsent(action); return }
    TVPointerFocus.remoteInput()
    if playbackQualityVisible {
      switch action {
      case .up, .left: qualitySelection = max(0, qualitySelection - 1)
      case .down, .right: qualitySelection = min(bilibiliQualityOptions.count, qualitySelection + 1)
      case .select: choosePlaybackQuality(qualitySelection)
      case .back, .menu: playbackQualityVisible = false; showPlayerControls()
      case .home: playbackQualityVisible = false; stopPlayback()
      default: break
      }
      return
    }
    if case .back = action, returnFromTopmostMenu() { return }
    if notice != nil {
      if case .select = action { notice = nil }
      return
    }
    if information.isPresented { information.handle(action); return }
    if navigationCustomizationVisible { handleNavigationCustomization(action); return }
    if appearanceVisible { handleAppearance(action); return }
    if playbackVolumeVisible {
      switch action {
      case .left: playbackVolumeSelection = max(0, playbackVolumeSelection - 1)
      case .right: playbackVolumeSelection = min(2, playbackVolumeSelection + 1)
      case .up: adjustPlaybackVolume(0.05)
      case .down: adjustPlaybackVolume(-0.05)
      case .select:
        if playbackVolumeSelection == 1 { togglePlaybackMute() }
        else { adjustPlaybackVolume(playbackVolumeSelection == 0 ? -0.05 : 0.05) }
      case .back, .menu: playbackVolumeVisible = false; showPlayerControls()
      case .home: stopPlayback()
      default: break
      }
      return
    }
    if accountSettingsVisible && !login.isPresented && !keyboardVisible {
      let accounts = plugins.filter { $0.manifest.authentication != nil }
      switch action {
      case .up, .left: accountSettingsIndex = max(0, accountSettingsIndex - 1)
      case .down, .right: accountSettingsIndex = min(accounts.count, accountSettingsIndex + 1)
      case .select:
        if accounts.indices.contains(accountSettingsIndex) { showLogin(accounts[accountSettingsIndex]) }
        else { accountSettingsVisible = false }
      case .back, .home, .menu: accountSettingsVisible = false
      default: break
      }
      return
    }
    if playbackSpeedVisible {
      switch action {
      case .left, .up: playbackSpeedIndex = max(0, playbackSpeedIndex - 1)
      case .right, .down: playbackSpeedIndex = min(playbackRates.count - 1, playbackSpeedIndex + 1)
      case .select: applyPlaybackRate(playbackRates[playbackSpeedIndex])
      case .back, .menu: playbackSpeedVisible = false; showPlayerControls()
      case .home: stopPlayback()
      default: break
      }
      return
    }
    if watchlist.menuID != nil, notice == nil {
      switch action {
      case .left, .up: watchlist.menuIndex = max(0, watchlist.menuIndex - 1)
      case .right, .down: watchlist.menuIndex = min(2, watchlist.menuIndex + 1)
      case .select: watchlist.activateMenu()
      case .back, .home, .menu: watchlist.menuID = nil
      default: break
      }
      return
    }
    if continueWatching.recoveryPresented, notice == nil {
      guard !continueWatching.recoveryBusy else { return }
      switch action {
      case .left, .up: continueWatching.recoverySelection = 0
      case .right, .down: continueWatching.recoverySelection = continueWatching.recoveryReview == nil ? 0 : 1
      case .select: continueWatching.activateRecovery()
      case .back, .home, .menu: continueWatching.closeRecovery()
      default: break
      }
      return
    }
    if continueWatching.menuID != nil, notice == nil {
      switch action {
      case .left, .up: continueWatching.menuIndex = max(0, continueWatching.menuIndex - 1)
      case .right, .down: continueWatching.menuIndex = min(2, continueWatching.menuIndex + 1)
      case .select: continueWatching.activateMenu()
      case .back, .home, .menu: continueWatching.menuID = nil
      default: break
      }
      return
    }
    if notice != nil {
      if case .select = action { notice = nil }
      if case .back = action { notice = nil }
      return
    }
    if libraryOverview.isPresented && !keyboardVisible {
      switch action {
      case .left: libraryOverview.move(dx: -1, dy: 0)
      case .right: libraryOverview.move(dx: 1, dy: 0)
      case .up: libraryOverview.move(dx: 0, dy: -1)
      case .down: libraryOverview.move(dx: 0, dy: 1)
      case .select:
        if libraryOverview.versionsPresented { libraryOverview.activate() }
        else if libraryOverview.row == 0 && libraryOverview.column == 1 { presentLibraryOverview() }
        else if libraryOverview.row == 0 && libraryOverview.column == 2 { showOverviewKeyboard() }
        else if libraryOverview.row == 0 && libraryOverview.column == 3 { searchLibraryOverview("") }
        else { libraryOverview.activate() }
      case .back: libraryOverview.back()
      case .home: libraryOverview.close(); returnToOverview = false; navigate(.home)
      default: break
      }
      return
    }
    if pluginFolders.isPresented && !keyboardVisible {
      switch action {
      case .up: pluginFolders.move(-1)
      case .down: pluginFolders.move(1)
      case .left: pluginFolders.moveColumn(-1)
      case .right: pluginFolders.moveColumn(1)
      case .select: pluginFolders.activate()
      case .back, .home: pluginFolders.close()
      default: break
      }
      return
    }
    if pluginManager.isPresented && !keyboardVisible {
      switch action {
      case .up, .left: pluginManager.move(-1)
      case .down, .right: pluginManager.move(1)
      case .select: pluginManager.activate()
      case .back, .home: pluginManager.back()
      default: break
      }
      return
    }
    if audioOutputVisible {
      switch action {
      case .back, .home: audioOutputVisible = false
      case .up, .left: audioOutputIndex = max(0, audioOutputIndex - 1)
      case .down, .right: audioOutputIndex = min(audioOutputDevices.count + 1, audioOutputIndex + 1)
      case .select: chooseAudioOutput(audioOutputIndex)
      default: break
      }
      return
    }
    if enginePickerVisible {
      switch action {
      case .back, .home: enginePickerVisible = false
      case .left, .up: enginePickerIndex = max(0, enginePickerIndex - 1)
      case .right, .down:
        enginePickerIndex = min(PlaybackEngineChoice.allCases.count - 1, enginePickerIndex + 1)
      case .select: selectEngine(PlaybackEngineChoice.allCases[enginePickerIndex])
      default: break
      }
      return
    }
    if login.isPresented {
      switch action {
      case .back, .home: login.close()
      case .left, .up: login.move(-1)
      case .right, .down: login.move(1)
      case .select: login.activate(allowChromeImport: chromeImportAllowed, allowInteraction: interactiveLoginAllowed)
      default: break
      }
      return
    }
    if keyboardVisible {
      switch action {
      case .back:
        finishTextEntry(commit: false)
        rebuildFocus()
      case .delete: backspace()
      case .text(let text):
        if chinese,
          text.unicodeScalars.allSatisfy({
            (65...90).contains($0.value) || (97...122).contains($0.value) || $0.value == 39
          })
        {
          insertPinyin(text.lowercased())
        } else {
          finishComposition()
          inputText += text
        }
      case .up:
        if keyboardFocus.row == 0, !candidates.isEmpty {
          candidateFocus = true
        } else if !candidateFocus {
          keyboardFocus.move(dx: 0, dy: -1)
        }
      case .down:
        if candidateFocus { candidateFocus = false } else { keyboardFocus.move(dx: 0, dy: 1) }
      case .left:
        if candidateFocus {
          candidateIndex = max(0, candidateIndex - 1)
        } else {
          keyboardFocus.move(dx: -1, dy: 0)
        }
      case .right:
        if candidateFocus {
          candidateIndex = min(max(0, candidateActions.count - 1), candidateIndex + 1)
        } else {
          keyboardFocus.move(dx: 1, dy: 0)
        }
      case .select:
        if candidateFocus {
          commitCandidate()
        } else {
          pressKey(keyboardRows[keyboardFocus.row][keyboardFocus.column])
        }
      default: break
      }
      return
    }
    if libraryBrowser.isPresented {
      switch action {
      case .up: libraryBrowser.move(dx: 0, dy: -1)
      case .down: libraryBrowser.move(dx: 0, dy: 1)
      case .left: libraryBrowser.move(dx: -1, dy: 0)
      case .right: libraryBrowser.move(dx: 1, dy: 0)
      case .select: libraryBrowser.activate()
      case .back, .menu: libraryBrowser.close()
      case .home: libraryBrowser.close(); navigate(.home)
      default: break
      }
      return
    }
    if checkingModuleContinuation {
      switch action {
      case .back, .menu, .select: cancelCheckingModuleContinuation()
      case .home: stopPlayback()
      default: break
      }
      return
    }
    if episodeChoices != nil {
      switch action {
      case .up, .left: episodeChoiceIndex = max(0, episodeChoiceIndex - 1)
      case .down, .right: episodeChoiceIndex = min(episodeChoices?.candidates.count ?? 0, episodeChoiceIndex + 1)
      case .select: activateEpisodeChoice()
      case .back, .home, .menu: dismissEpisodeChoices()
      default: break
      }
      return
    }
    if playbackTracks.isPresented {
      switch action {
      case .up, .left: playbackTracks.move(-1)
      case .down, .right: playbackTracks.move(1)
      case .select: playbackTracks.activate()
      case .back, .home, .menu: playbackTracks.close()
      default: break
      }
      return
    }
    if videoPresentation.isPresented {
      switch action {
      case .up, .left: videoPresentation.move(-1)
      case .down, .right: videoPresentation.move(1)
      case .select: videoPresentation.activate()
      case .back, .home: videoPresentation.close()
      default: break
      }
      return
    }
    if savedSources.isPresented {
      switch action {
      case .up: savedSources.move(-1)
      case .down: savedSources.move(1)
      case .left: savedSources.moveColumn(-1)
      case .right: savedSources.moveColumn(1)
      case .select: savedSources.activate()
      case .menu: savedSources.moveColumn(1)
      case .back, .home: savedSources.back()
      default: break
      }
      return
    }
    if sourceSetup.isPresented && !localFolders.isPresented && !smb.isPresented {
      switch action {
      case .left: sourceSetup.move(-1)
      case .right: sourceSetup.move(1)
      case .up: sourceSetup.moveVertical(-1)
      case .down: sourceSetup.moveVertical(1)
      case .select: sourceSetup.activate()
      case .back, .home: continueWithoutLocalSource(destination: .home)
      default: break
      }
      return
    }
    if localFolders.isPresented {
      switch action {
      case .back, .home: localFolders.close()
      case .up: localFolders.move(-1)
      case .down: localFolders.move(1)
      case .left: localFolders.moveColumn(-1)
      case .right: localFolders.moveColumn(1)
      case .select: localFolders.activate()
      default: break
      }
      return
    }
    if automaticMetadata.isPresented && !metadata.isPresented {
      switch action {
      case .back, .home:
        if automaticMetadata.phase == "running" {
          automaticMetadata.cancel()
        } else {
          automaticMetadata.close()
        }
      case .up, .left: automaticMetadata.move(-1)
      case .down, .right: automaticMetadata.move(1)
      case .select: automaticMetadata.activate()
      default: break
      }
      return
    }
    if metadata.isPresented {
      switch action {
      case .back, .home: metadata.close()
      case .up: metadata.moveVertical(-1)
      case .down: metadata.moveVertical(1)
      case .left: metadata.moveHorizontal(-1)
      case .right: metadata.moveHorizontal(1)
      case .select: metadata.activate()
      default: break
      }
      return
    }
    if smb.isPresented {
      switch action {
      case .back: smb.back()
      case .home: smb.close()
      case .up, .left: smb.move(-1)
      case .down, .right: smb.move(1)
      case .select: smb.activate()
      default: break
      }
      return
    }
    if preparingPlayback || loadingNextVideo {
      switch action {
      case .back: stopPlayback()
      case .home:
        stopPlayback()
        navigate(.home)
      default: break
      }
      return
    }
    if playbackPresented {
      if playbackInterruption != nil {
        switch action {
        case .left: playbackInterruptionButton = 0
        case .right: playbackInterruptionButton = 1
        case .select: playbackInterruptionCommand(playbackInterruptionButton)
        case .back, .home: stopPlayback()
        default: break
        }
        return
      }
      if playbackCompleted {
        if case .back = action { returnAfterPlayback() }
        if case .home = action { returnAfterPlayback() }
        return
      }
      switch action {
      case .back:
        if playerControlsVisible { cancelPlayerScrub(); controlsTask?.cancel(); playerControlsVisible = false }
        else { stopPlayback() }
      case .home: stopPlayback()
      case .left:
        if playerControlsVisible {
          if playerTimelineFocused { movePlayerScrub(-10) } else { movePlayerControl(-1) }
          showPlayerControls()
        } else { movePlayerScrub(-10) }
      case .right:
        if playerControlsVisible {
          if playerTimelineFocused { movePlayerScrub(10) } else { movePlayerControl(1) }
          showPlayerControls()
        } else { movePlayerScrub(10) }
      case .up:
        if playerScrub == nil { beginPlayerScrub() }
      case .down:
        cancelPlayerScrub(); playerButton = 1; showPlayerControls()
      case .menu: showPlayerControls()
      case .select:
        if playerTimelineFocused { if playerScrub != nil { _ = commitPlayerScrub() } }
        else { playerCommand(playerControlsVisible ? playerButton : 1) }
      default: break
      }
      return
    }
    if detail != nil {
      switch action {
      case .left: detailAction = max(0, detailAction - 1)
      case .right: detailAction = min(detail.map { detailControls(for: $0).count - 1 } ?? 0, detailAction + 1)
      case .menu: break
      case .back, .home:
        playbackRequestID = UUID()
        loading = false
        closeHistoryDetail()
      case .select:
        if let detail {
          let controls = detailControls(for: detail)
          if controls.indices.contains(detailAction) { performDetailControl(controls[detailAction], item: detail) }
        }
      default: break
      }
      return
    }
    if setupGuideVisible {
      let count = guideActions.count
      let indices = Array(0..<count) + (setupGuideStep > 0 ? [count]:[]) + [count + 2,count + 1]
      let index = indices.firstIndex(of:setupGuideSelection) ?? 0
      switch action {
      case .up,.left: setupGuideSelection = indices[max(0,index - 1)]
      case .down,.right: setupGuideSelection = indices[min(indices.count - 1,index + 1)]
      case .select: activateSetupGuide()
      case .back,.menu:
        if setupGuideStep > 0 { setupGuideStep -= 1; setupGuideSelection = 0 }
        else { finishSetupGuide(completed:false) }
      case .home: finishSetupGuide(completed:false); navigate(.home)
      default: break
      }
      return
    }
    switch action {
    case .up: moveMainFocus(dx: 0, dy: -1)
    case .down: moveMainFocus(dx: 0, dy: 1)
    case .left: moveMainFocus(dx: -1, dy: 0)
    case .right: moveMainFocus(dx: 1, dy: 0)
    case .select: activate()
    case .back:
      if !backModuleFolder() && !backLibraryCollection() {
        if section == .library && returnToOverview { returnToOverview = false; presentLibraryOverview(reload: false) }
        else { navigate(.home) }
      }
    case .home: navigate(.home)
    case .menu:
      if section == .home, focus.row == 3, continueWatching.entries.indices.contains(focus.column) {
        continueWatching.menu(continueWatching.entries[focus.column].id)
      } else if section == .home, focus.row == watchlistRow, watchlist.entries.indices.contains(focus.column) {
        watchlist.menu(watchlist.entries[focus.column].id)
      } else { navigate(.settings) }
    default: break
    }
  }
  func performSetting(_ setting: TVSetting) {
    settingsGroup = setting.row; settingsSidebarFocus = false
    focus.select(row: setting.row, column: setting.column)
    switch setting {
    case .sources: presentSavedSources()
    case .addFolder: chooseRoot()
    case .nas: smb.present()
    case .scan: scanLibrary(forceFull: true)
    case .engine:
      guard CommandLine.arguments.contains("--ui-smoke") else { return }
      enginePickerIndex = PlaybackEngineChoice.allCases.firstIndex(of: preferredEngine) ?? 0
      enginePickerVisible = true
    case .audio: presentAudioOutputs()
    case .metadata: prepareAutomaticMetadata()
    case .fullscreen: NSApp.keyWindow?.toggleFullScreen(nil)
    case .accounts:
      for plugin in plugins where plugin.manifest.authentication != nil { login.refresh(plugin) }
      accountSettingsIndex = 0; accountSettingsVisible = true
    case .history: continueWatching.presentRecovery()
    case .plugins: pluginManager.present()
    case .about: presentSetupGuide()
    case .information: information.present()
    case .appearance: appearanceSelection = TVAppearance.allCases.firstIndex(of: appearance) ?? 0; appearanceVisible = true
    case .navigation: navigationCustomizationIndex = 0; navigationCustomizationVisible = true
    }
  }
  func activate() {
    let row = focus.row
    let col = focus.column
    if row == 0 {
      focusNavigation(at: col)
      return
    }
    if section == .home, row == 1 {
      if let selectedHero { activateCard(selectedHero) }
      else if needsSMBReconnect { reconnectSMB() }
      else { presentSourceSetup() }
      return
    }
    if section == .home, row == 2 {
      if col == 0 {
        navigate(.library)
      } else if col <= homePlugins.count {
        openModule(homePlugins[col - 1])
      } else {
        showKeyboard()
      }
      return
    }
    if section == .home, row == 3, !continueWatching.entries.isEmpty {
      if continueWatching.entries.indices.contains(col) { continueWatching.open(continueWatching.entries[col].id) }
      return
    }
    if section == .home, row == watchlistRow, !watchlist.entries.isEmpty {
      if watchlist.entries.indices.contains(col) { watchlist.open(watchlist.entries[col].id) }
      return
    }
    if section == .extensions {
      if col < plugins.count {
        openModule(plugins[col])
      } else {
        pluginManager.present()
      }
      return
    }
    if section == .settings {
      if settingsSidebarFocus { settingsSidebarFocus = false; return }
      if let setting = TVSetting.visibleSetting(row: row, column: col) { performSetting(setting) }
      return
    }
    if hasBilibiliTabs, row == bilibiliChannelRow { selectBilibiliChannel(at: col); return }
    if row == (section == .bilibili ? moduleToolbarRow : 1) {
      if section == .bilibili, moduleSupportsLookup, col == moduleLookupColumn { showModuleLookup(); return }
      if section == .library, libraryPath.isEmpty, col == overviewColumn { presentLibraryOverview(); return }
      if section == .library, libraryPath.isEmpty, col == savedSourcesColumn { presentSavedSources(); return }
      if section == .library, libraryPath.isEmpty, col == libraryBrowseColumn { presentLibraryBrowse(); return }
      if section == .library && needsSMBReconnect && col == smbReconnectColumn { reconnectSMB(); return }
      if section == .library, col == 2, let series = libraryPath.first {
        metadata.present(series)
        return
      }
      if section == .library, col == 1, !libraryPath.isEmpty {
        backLibraryCollection()
        return
      }
      if section == .bilibili, col == moduleAccountColumn, let plugin = activePlugin,
        plugin.manifest.authentication != nil
      {
        showLogin(plugin)
        return
      }
      if section == .bilibili {
        modulePrimaryAction()
      } else if section == .library && !hasLibrarySource {
        presentSourceSetup()
      } else {
        showKeyboard()
      }
      return
    }
    if section == .bilibili, row == mediaFocusOffset + mediaRows.count, moduleHasFooter {
      guard !foregroundLoading else { return }
      if moduleLoadFailure != nil { retryModuleLoad(); return }
      guard let page = moduleNextPage else { return }
      loadModule(
        action: search.isEmpty ? "browse" : "search", input: ["query": search, "page": page],
        append: true)
      return
    }
    let index = (row - mediaFocusOffset) * gridColumns + col
    if index >= 0, index < visibleItems.count { activateCard(visibleItems[index]) }
  }
  func showLogin(_ plugin: PluginRecord) {
    resumeModuleOnLoginDismiss = loading
    loadTask?.cancel()
    moduleGeneration = UUID()
    loading = false
    notice = nil
    keyboardVisible = false
    detail = nil
    playbackRequestID = UUID()
    login.present(plugin)
  }
  func chooseRoot() {
    let url = mediaRoot.isEmpty ? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
      : URL(fileURLWithPath: mediaRoot, isDirectory: true)
    localFolders.present(at: url)
  }
  func showLocalPath() {
    savedKeyboardMode = (chinese, uppercase)
    textEntryTarget = .localPath
    keyboardDraft = localFolders.directory?.path ?? "~/Movies"
    keyboardSymbols = false
    clearPinyin()
    chinese = false
    uppercase = false
    keyboardFocus = FocusGrid(rows: keyboardRows.map(\.count))
    keyboardVisible = true
  }
  func useLocalRoot(_ url: URL, title: String? = nil) {
    sourceEditorReturnsToSavedSources = false
    scanIncremental = nil; scanIncrementalContext = nil
    let url = url.standardizedFileURL
    sourceSwitchID = UUID()
    libraryCommitTask?.cancel()
    libraryScanWorker?.cancel()
    libraryScanTimeout?.cancel()
    sourceNeedsSetup = false
    sourceSetup.close()
    automaticMetadata.close()
    libraryMaintenance.sourceChanged()
    libraryScanID = UUID()
    currentSMBBoundary = nil
    currentSMBProfile = nil
    currentSMBAddress = ""
    smbMountInvalid = false
    networkRecovery.deactivate()
    pendingSMBPlayback = nil
    mediaRoot = url.path
    libraryIndexedAt = nil
    libraryIndexError = nil
    persistSourceSelection(LibrarySourceSelection(path: url.path), title: title)
    navigate(.library)
    applyLibraryItems([])
    restoreLibraryFromIndex()
  }
  func chooseRootUsingSystemPanel() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.message = "选择影片目录（只读，不移动或重命名文件）"
    panel.begin { [weak self] result in
      if result == .OK, let url = panel.url {
        self?.useLocalRoot(url)
      } else { self?.sourceEditorCancelled() }
    }
  }
  func sourceTitle(for item: MediaItem) -> String {
    item.source == "local"
      ? (currentSMBProfile == nil && currentSMBBoundary == nil ? L("你的影片库") : L("NAS 影片库"))
      : (plugins.first { $0.id == item.source }?.title ?? L("应用"))
  }
  func play(_ item: MediaItem, fromBeginning: Bool = false, sessionAccessOverride: PluginClient.SessionAccess? = nil, switchingVideo: Bool = false) {
    if item.kind == .photo || item.kind == .audio { openNativeMedia(item); return }
    mediaSessionConsent = nil
    guard !foregroundLoading else { return }
    if item.source != "mtv.bilibili" || pendingQualityResume?.itemID != item.id { pendingQualityResume = nil }
    smokePlaybackResolution = [:]
    smokePlaybackFailureDetails = []
    smokeTimeoutGeneration = nil
    if item.source == "local" && needsSMBReconnect {
      // A reconnect preserves the user's explicit starting-point choice by recording it in memory.
      pendingSMBPlayback = PendingSMBPlayback(id: item.id, fromBeginning: fromBeginning)
      reconnectSMB()
      return
    }
    let requestID = UUID()
    playbackRequestID = requestID
    let sessionAccess = sessionAccessOverride ?? moduleSessionAccess
    if item.source != "local", let plugin = plugins.first(where: { $0.id == item.source }) {
      if switchingVideo { preparingPlayback = true }
      loading = true
      playbackResolveTask = Task {
        defer {
          if playbackRequestID == requestID {
            loading = false; playbackResolveTask = nil
            if switchingVideo && preflightTask == nil { preparingPlayback = false }
          }
        }
        do {
          var resolveInput = ["reference": item.reference ?? item.id]
          if plugin.id == "mtv.quark", item.title.lowercased().hasSuffix(".mkv") || (CommandLine.arguments.contains("--ui-smoke") && CommandLine.arguments.contains("--benchmark-original-file")) { resolveInput["original"] = "true" }
          if plugin.id == "mtv.bilibili" { resolveInput["quality"] = bilibiliQualityPreference }
          if CommandLine.arguments.contains("--ui-smoke"), let option = CommandLine.arguments.firstIndex(of: "--test-resolve-transport"),
            option + 1 < CommandLine.arguments.count {
            let value = CommandLine.arguments[option + 1]
            guard ["dash", "progressive"].contains(value) else { throw MTVError.message("无效的测试传输选项") }
            resolveInput["transport"] = value
          }
          let data = try await PluginClient.execute(
            plugin, action: "resolve", input: resolveInput, sessionAccess: sessionAccess)
          guard playbackRequestID == requestID, activePlugin?.id == plugin.id, section == .bilibili
          else { return }
          let stream = try JSONDecoder().decode(PlaybackDescriptor.self, from: data)
          if plugin.id == "mtv.bilibili" { receiveBilibiliQuality(stream) }
          markPlaybackBenchmark("resolveComplete")
          let continuation: ModulePlaybackContinuation?
          var resolvedItem = item
          if plugin.id == "mtv.bilibili" {
            if let owner = stream.videoOwner, !owner.isEmpty { resolvedItem.subtitle = String(owner.prefix(160)) }
            if let overview = stream.videoOverview, !overview.isEmpty { resolvedItem.overview = String(overview.prefix(2000)) }
          }
          if let declared = stream.continuation {
            let collection = item.collectionReference ?? modulePath.last?.reference
            let requested = item.reference ?? item.id
            let value = try declared.validated(manifest: plugin.manifest, currentID: item.id,
              expectedCurrent: requested == collection ? nil : requested, expectedCollection: collection)
            continuation = ModulePlaybackContinuation(pluginID: plugin.id, version: plugin.manifest.version, directory: plugin.directory,
              sessionAccess: sessionAccess, currentID: item.id, value: value)
            resolvedItem.reference = value.currentReference; resolvedItem.collectionReference = value.collectionReference
          } else { continuation = nil }
          guard stream.transport == nil || ["indexed-fmp4", "original-matroska"].contains(stream.transport!) else { throw MTVError.message("模块返回了不支持的播放传输") }
          guard let url = URL(string: stream.url),
            NetworkPolicy.permitsPlayback(url, domains: plugin.manifest.playbackDomains ?? [])
          else { throw MTVError.message("播放地址不在插件声明的播放域名范围") }
          if let expiry = stream.expiresAt, expiry <= Date().timeIntervalSince1970 {
            throw MTVError.message("插件返回的播放地址已过期")
          }
          var request = try RemotePlaybackRequest(url: url, domains: plugin.manifest.playbackDomains ?? [],
            headers: stream.headers ?? [:], referer: plugin.manifest.playbackReferer)
          // This development option is off by default. The diagnostic-only
          // approval does not itself enable production media authentication.
          if plugin.id == "mtv.quark", let mediaHost = url.host, FirstPartyMediaScope.isQuarkPlaybackHost(mediaHost) {
            guard hasMediaSessionApproval(pluginID: plugin.id, host: mediaHost) else {
              mediaSessionConsent = MediaSessionConsent(requestID: requestID, pluginID: plugin.id,
                host: mediaHost, item: item, fromBeginning: fromBeginning)
              mediaSessionConsentSelection = 1
              return
            }
            guard sessionAccess == .stored,
              let credential = try await Task.detached(operation: { try PluginSessionStore().load(pluginID: plugin.id) }).value
            else { throw MTVError.message("夸克播放会话未获当前精确主机授权") }
            try credential.validate(for: plugin.manifest)
            request = try request.authorizingMediaSession(credential, approvedHost: mediaHost,
              quarkPlaybackService: MediaSessionApprovalStore().quarkPlaybackServiceApproved)
          }
          var audio: RemotePlaybackRequest?
          if let value = stream.audioURL {
            guard let audioURL = URL(string: value) else { throw MTVError.message("音频片源地址无效") }
            audio = try RemotePlaybackRequest(url: audioURL, domains: plugin.manifest.playbackDomains ?? [],
              headers: stream.headers ?? [:], referer: plugin.manifest.playbackReferer)
          }
          guard stream.transport != "indexed-fmp4" || audio != nil else { throw MTVError.message("索引播放必须提供独立音频地址") }
          if CommandLine.arguments.contains("--ui-smoke") {
            playbackBenchmark?.metadata["nativeMediaSessionHost"] = request.carriesNativeSession ? (url.host ?? "unknown") : "none"
            smokePlaybackResolution = ["plugin": plugin.id, "reference": item.reference ?? item.id,
              "qualityCode": stream.quality ?? -1, "qualityTitle": stream.qualityTitle ?? "", "height": stream.height ?? -1, "bandwidth": stream.bandwidth ?? -1, "availableQualityCodes": (stream.qualities ?? []).filter(\.available).map(\.id), "note": stream.note ?? "", "hasSeparateAudio": audio != nil,
              "mediaHost": url.host ?? "", "headerNames": request.headers.keys.sorted(), "requestedTransport": resolveInput["transport"] ?? "automatic"]
          }
          if stream.transport == "original-matroska" { beginOriginalRemotePlayback(request: request, item: resolvedItem, fromBeginning: fromBeginning) }
          else if !request.requiresNativeLoader && audio == nil { beginPlayback(url: url, item: resolvedItem, fromBeginning: fromBeginning, moduleContinuation: continuation) }
          else { beginRemotePlayback(video: request, audio: audio, item: resolvedItem, indexed: stream.transport == "indexed-fmp4", fromBeginning: fromBeginning, moduleContinuation: continuation) }
        } catch {
          if playbackRequestID == requestID {
            if switchingVideo && playbackCompleted { returnAfterPlayback() }
            if let restart = pendingQualityResume, playingItem?.id == restart.itemID, let player {
              paused = restart.paused; if !restart.paused { player.playImmediately(atRate: playbackRate) }
            }
            pendingQualityResume = nil
            notice = "播放失败：\(error.localizedDescription)"
          }
        }
      }
    } else if item.source == "local", let address = item.url, let url = URL(string: address), url.isFileURL {
      beginPlayback(url: url, item: item, fromBeginning: fromBeginning)
    } else {
      notice = "此卡片没有可播放的媒体地址"
    }
  }
  private func makeSubtitleContext(url: URL, item: MediaItem) -> LocalSubtitlePlaybackContext? {
    guard item.source == "local", url.isFileURL, !mediaRoot.isEmpty else { return nil }
    let root = URL(fileURLWithPath: mediaRoot).standardizedFileURL
    let declared = item.url.flatMap(URL.init(string:))?.standardizedFileURL
    func inside(_ file: URL) -> Bool { file.isFileURL && file.path.hasPrefix(root.path == "/" ? "/" : root.path + "/") }
    guard inside(url) || declared.map(inside) == true else { return nil }
    let access: ScopedFileAccess
    if let boundary = currentSMBBoundary {
      guard let share = try? currentValidatedSMBShare(boundary) else { return nil }
      access = .verifiedSMB(share)
    } else { access = .within(root) }
    return LocalSubtitlePlaybackContext(media: url, item: item, access: access)
  }
  func restartForSubtitle(_ subtitle: PreparedLocalSubtitle?, context: LocalSubtitlePlaybackContext, automatic: Bool = false) -> Bool {
    let engine: PlaybackEngineChoice = CommandLine.arguments.contains("--ui-smoke") && preferredEngine == .vlc ? .vlc : .mpv
    guard localSubtitleContext?.token == context.token, playbackPresented,
      (engine == .mpv ? MPVPlaybackEngine.isAvailable : VLCPlaybackEngine.isAvailable), !Task.isCancelled else { return false }
    let time = player?.currentTime().seconds ?? vlcEngine?.latest?.elapsed ?? elapsed
    let length = player?.currentItem?.duration.seconds ?? duration
    guard time.isFinite, time >= 0 else { return false }
    let position = length.isFinite && length > 0 ? min(time, max(0, length - 0.25)) : time
    let request = SubtitlePlaybackRestart(subtitle: subtitle, position: position, paused: paused, userSubtitleChoice: !automatic, engine: engine)
    beginPlayback(url: context.media, item: context.item, subtitleRestart: request)
    return true
  }
  func beginPlayback(url: URL, item: MediaItem, fromBeginning: Bool = false, subtitleRestart: SubtitlePlaybackRestart? = nil, moduleContinuation: ModulePlaybackContinuation? = nil) {
    if let restart = subtitleRestart, !restart.position.isFinite || restart.position < 0 { notice = "播放位置无效"; return }
    stopPlayback(invalidateRequest: false)
    playbackSelectionReason = ""
    let choice = subtitleRestart?.engine ?? preferredEngine
    let boundary = item.source == "local" ? currentSMBBoundary : nil
    let verifiedShare: MountedSMBShare?
    do { verifiedShare = try currentValidatedSMBShare(boundary) }
    catch { markSMBMountUnavailable(error); notice = error.localizedDescription; return }
    preparingPlayback = true
    let generation = UUID()
    preflightGeneration = generation
    preflightTask = Task { [weak self] in
      do {
        try verifiedShare?.validateCurrentMount()
        let resolved = try await PlaybackPreflight.checkedURL(url, boundary: boundary)
        let selection: PlaybackSelection
        if choice == .automatic {
          selection = try await PlaybackPreflight.inspect(resolved)
        } else {
          selection = PlaybackSelection(engine: choice, asset: nil, reason: subtitleRestart == nil ? "手动选择：" + choice.title : "手动选择外挂字幕 · 从当前位置使用通用播放")
        }
        let containerPlan = selection.engine == .vlc ? try await PlaybackPreflight.vlcContainerPlan(resolved) : .standard
        guard let self, !Task.isCancelled, self.preflightGeneration == generation else { return }
        try verifiedShare?.validateCurrentMount()
        self.preflightTask = nil
        self.preparationWatchdog?.cancel()
        self.preparationWatchdog = nil
        self.preparingPlayback = false
        self.playbackSelectionReason = selection.reason + (selection.engine == .vlc ? " · " + containerPlan.reason : "")
        self.startSelectedPlayback(
          url: resolved, item: item, engine: selection.engine, asset: selection.asset, fromBeginning: fromBeginning, containerPlan: containerPlan, subtitleRestart: subtitleRestart, moduleContinuation: moduleContinuation)
      } catch {
        guard let self, !Task.isCancelled, self.preflightGeneration == generation else { return }
        self.stopPlayback(invalidateRequest: false)
        if (error as? SMBFailure)?.stage == .mountValidation { self.markSMBMountUnavailable(error) }
        self.notice = "无法读取片源：\(error.localizedDescription)"
      }
    }
    watchPlaybackPreparation(generation)
  }
  func beginHeaderPlayback(request: RemotePlaybackRequest, item: MediaItem) {
    beginRemotePlayback(video: request, audio: nil, item: item)
  }
  private func beginOriginalRemotePlayback(request: RemotePlaybackRequest, item: MediaItem, fromBeginning: Bool) {
    markPlaybackBenchmark("prepareStart")
    stopPlayback(invalidateRequest: false)
    let generation = UUID(); preflightGeneration = generation; preparingPlayback = true
    preflightTask = Task { [weak self] in
      do {
        let prepared = try await OriginalRemoteMedia.prepare(request)
        guard let self, self.preflightGeneration == generation, !Task.isCancelled else { prepared.cancel(); return }
        self.preflightTask = nil; self.preparingPlayback = false
        self.preparationWatchdog?.cancel(); self.preparationWatchdog = nil
        self.markPlaybackBenchmark("prepareComplete")
        self.beginMPVPlayback(url: prepared.url, item: item, fromBeginning: fromBeginning, original: prepared)
      } catch {
        guard let self, self.preflightGeneration == generation, !Task.isCancelled else { return }
        self.stopPlayback(invalidateRequest: false); self.notice = "Original playback failed: " + error.localizedDescription
      }
    }
    watchPlaybackPreparation(generation)
  }
  func beginRemotePlayback(video: RemotePlaybackRequest, audio: RemotePlaybackRequest?, item: MediaItem, indexed useIndex: Bool = false, fromBeginning: Bool = false, moduleContinuation: ModulePlaybackContinuation? = nil) {
    markPlaybackBenchmark("prepareStart")
    stopPlayback(invalidateRequest: false)
    guard preferredEngine != .vlc, preferredEngine != .mpv else {
      notice = "此网络片源需系统引擎，请在设置中选择自动或系统播放"
      return
    }
    let generation = UUID()
    preflightGeneration = generation; preparingPlayback = true
    preflightTask = Task { [weak self] in
      do {
        let indexed = useIndex || (CommandLine.arguments.contains("--ui-smoke") && CommandLine.arguments.contains("--test-indexed-hls"))
        let prepared = try await PreparedRemoteMedia.prepare(video: video, audio: audio, indexed: indexed) { [weak self] resources in
          guard let self, self.preflightGeneration == generation else { return }
          self.pendingRemoteResources = resources
        }
        try Task.checkCancellation()
        guard let self, self.preflightGeneration == generation else { prepared.cancel(); return }
        self.markPlaybackBenchmark("prepareComplete")
        if self.playbackBenchmark != nil {
          let benchmarkID = self.playbackBenchmark?.id
          let statistics = await prepared.preparationStatistics()
          guard self.preflightGeneration == generation, !Task.isCancelled else { prepared.cancel(); return }
          if self.playbackBenchmark?.id == benchmarkID {
            for (key, value) in statistics { self.playbackBenchmark?.metadata["prepare." + key] = String(value) }
          }
        }
        self.preflightTask = nil; self.preparationWatchdog?.cancel(); self.preparationWatchdog = nil
        self.preparingPlayback = false
        self.pendingRemoteResources = []
        self.startSelectedPlayback(url: prepared.primaryURL, item: item, engine: .system, asset: prepared.asset, fromBeginning: fromBeginning, moduleContinuation: moduleContinuation)
        self.remoteMedia = prepared
        if CommandLine.arguments.contains("--ui-smoke") {
          self.smokePlaybackResolution["adapter"] = prepared.indexedHLS == nil ? "composition" : "indexed-hls"
          self.playbackBenchmark?.metadata["playablePreparation"] = prepared.playablePreparation
          if let hls = prepared.indexedHLS { self.smokePlaybackResolution["loopbackPort"] = Int(hls.port) }
        }
        self.playbackSelectionReason = audio == nil ? "系统播放 · 已校验请求头与媒体范围响应" : "系统播放 · 独立音视频轨道"
      } catch {
        guard let self, self.preflightGeneration == generation, !Task.isCancelled else { return }
        self.stopPlayback(invalidateRequest: false)
        self.notice = "网络片源读取失败：" + error.localizedDescription
        if CommandLine.arguments.contains("--ui-smoke"), let issue = error as? RemotePreparationFailure,
          let bytes = try? JSONEncoder().encode(issue.observations), let value = try? JSONSerialization.jsonObject(with: bytes) as? [[String: Any]] {
          self.smokePlaybackFailureDetails = value
        }
      }
    }
    watchPlaybackPreparation(generation)
  }
  private func watchPlaybackPreparation(_ generation: UUID) {
    preparationWatchdog = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(15)) } catch { return }
      guard let self, self.preflightGeneration == generation, self.preparingPlayback else { return }
      let resources = self.pendingRemoteResources
      self.stopPlayback()
      self.notice = "片源读取超时。请检查网络或 macOS 访问提示后重试。"
      if CommandLine.arguments.contains("--ui-smoke") {
        self.smokeTimeoutGeneration = generation
        self.smokePreparationTrace = Task {
          var observations: [RemoteResponseObservation] = []
          for (index, resource) in resources.enumerated() {
            for var observation in await resource.observations() {
              observation.role = index == 0 ? "video" : "audio"; observations.append(observation)
            }
          }
          guard self.smokeTimeoutGeneration == generation,
            let data = try? JSONEncoder().encode(observations), let value = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
          self.smokePlaybackFailureDetails = value
        }
      }
    }
  }
  func waitForSmokePreparationTrace() async { await smokePreparationTrace?.value }
  func smokeRemoteStatistics() async -> [String: Int] {
    guard CommandLine.arguments.contains("--ui-smoke") else { return [:] }
    if let originalRemoteMedia {
      let value = await originalRemoteMedia.statistics()
      return ["originalRequests":value.requests,"originalBytes":value.received,"prefixHits":value.prefixHits]
    }
    guard let remoteMedia else { return [:] }
    if let hls = remoteMedia.indexedHLS { return await hls.statistics() }
    return await remoteMedia.preparationStatistics()
  }
  func smokeIndexedAudioDecode() async throws -> [String: Int] {
    guard CommandLine.arguments.contains("--ui-smoke"), let hls = remoteMedia?.indexedHLS else { throw CocoaError(.featureUnsupported) }
    return try await HLSSampleAudioProbe.decode(hls.testAudioSample())
  }
  private func startSelectedPlayback(
    url: URL, item: MediaItem, engine: PlaybackEngineChoice, asset: AVAsset? = nil, fromBeginning: Bool = false, containerPlan: VLCContainerPlan = .standard, subtitleRestart: SubtitlePlaybackRestart? = nil, moduleContinuation: ModulePlaybackContinuation? = nil
  ) {
    if item.source == "local", currentSMBBoundary != nil {
      do { _ = try currentValidatedSMBShare(currentSMBBoundary) }
      catch { markSMBMountUnavailable(error); notice = error.localizedDescription; return }
    }
    if engine == .mpv {
      beginMPVPlayback(url:url,item:item,fromBeginning:fromBeginning,subtitleRestart:subtitleRestart)
      return
    }
    if engine == .vlc {
      guard VLCPlaybackEngine.isAvailable else {
        notice = "当前片源选择了通用播放，但此构建没有包含该引擎。"
        return
      }
      beginVLCPlayback(url: url, item: item, fromBeginning: fromBeginning, containerPlan: containerPlan, subtitleRestart: subtitleRestart, moduleContinuation: moduleContinuation)
      return
    }
    stopPlayback(invalidateRequest: false)
    localSubtitleContext = makeSubtitleContext(url: url, item: item)
    modulePlaybackContinuation = moduleContinuation
    nextEpisodePlan = moduleContinuation?.value.plan(currentID: item.id) ?? EpisodeContinuation.plan(current: item, files: library)
    playbackTitle = item.title
    playbackState = "正在读取媒体…"
    currentMediaID = item.id
    lastSavedSecond = 0
    let qualityResume = item.source == "mtv.bilibili" && pendingQualityResume?.itemID == item.id ? pendingQualityResume : nil
    pendingQualityResume = nil
    let savedPosition = qualityResume?.position ?? (fromBeginning ? 0 : (resumeStore.record(for: item.id, source: item.source)?.resumablePosition ?? 0))
    protectsUnverifiedResume = savedPosition > 0
    systemResumeAttempted = false
    let avItem = asset.map { AVPlayerItem(asset: $0) } ?? AVPlayerItem(url: url)
    if CommandLine.arguments.contains("--ui-smoke"), let option = CommandLine.arguments.firstIndex(of: "--test-forward-buffer-seconds"),
      option + 1 < CommandLine.arguments.count, let seconds = Double(CommandLine.arguments[option + 1]),
      seconds.isFinite, (0...120).contains(seconds) { avItem.preferredForwardBufferDuration = seconds }
    avItem.appliesPerFrameHDRDisplayMetadata = true
    videoPresentation.inspect(avItem)
    let avPlayer = AVPlayer(playerItem: avItem)
    avPlayer.appliesMediaSelectionCriteriaAutomatically = false
    do { avPlayer.audioOutputDeviceUniqueID = try AudioOutputHardware.resolve()?.uid }
    catch { notice = error.localizedDescription; return }
    avPlayer.isMuted = CommandLine.arguments.contains("--ui-smoke") && !AudioOutputHardware.audibleTest
    avPlayer.volume = effectivePlaybackVolume
    if CommandLine.arguments.contains("--ui-smoke") {
      avPlayer.volume = AudioOutputHardware.audibleTest ? 0.1 : 0
      let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ])
      avItem.add(output)
      testVideoOutput = output
    }
    player = avPlayer
    if let benchmarkID = playbackBenchmark?.id {
      benchmarkTimeObserver = avPlayer.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self, weak avPlayer] value, _ in
        let state = value.timeControlStatus
        Task { @MainActor in
          guard let self, let avPlayer, self.player === avPlayer, self.playbackBenchmark?.id == benchmarkID else { return }
          if state == .playing { self.markPlaybackBenchmark("timelinePlaying") }
          if state == .waitingToPlayAtSpecifiedRate, self.playbackBenchmark?.milestonesMS["timelinePlaying"] != nil {
            self.markPlaybackBenchmark("firstRebuffer")
          }
        }
      }
    }
    playbackSourceID = item.source
    playbackRetryItem = item
    playbackRetryFromBeginning = fromBeginning
    beginHistoryForPlayback(item)
    playbackEndFailureObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemFailedToPlayToEndTime, object: avItem, queue: .main
    ) { [weak self, weak avItem] _ in
      Task { @MainActor in
        guard let self, let avItem, self.player?.currentItem === avItem else { return }
        self.presentPlaybackInterruption("播放已中断。可以重新播放，或返回选择其他内容。", failure: true)
      }
    }
    playbackCompletionObserver = NotificationCenter.default.addObserver(
      forName: .AVPlayerItemDidPlayToEndTime, object: avItem, queue: .main
    ) { [weak self, weak avItem] _ in
      Task { @MainActor in
        guard let self, let avItem, self.player?.currentItem === avItem else { return }
        self.markPlaybackCompleted()
      }
    }
    paused = qualityResume?.paused ?? false
    elapsed = 0
    duration = 0
    playerButton = 1
    playerControlsVisible = true
    observer = avItem.observe(\.status, options: [.new, .initial]) { [weak self] item, _ in
      Task { @MainActor in
        guard let self, self.player?.currentItem === item else { return }
        switch item.status {
        case .failed:
          self.presentPlaybackInterruption("播放已中断。可以重新播放，或返回选择其他内容。", failure: true)
        case .readyToPlay:
          self.markPlaybackBenchmark("itemReady")
          self.playbackState = "AVFoundation · 未验证 HDR / Dolby 输出"
          self.showPlayerControls()
          self.duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
          if savedPosition > 0, !self.systemResumeAttempted {
            self.systemResumeAttempted = true
            guard qualityResume != nil ? (self.duration > 0 && savedPosition < self.duration - 0.25) : (self.duration > 30 && savedPosition < self.duration - 15) else {
              avPlayer.pause(); self.paused = true
              self.presentPlaybackInterruption("片源长度已变化或尚不能定位，请返回后选择从头播放。原进度已保留。", failure: true)
              return
            }
            let restored = await avPlayer.seek(to: CMTime(seconds: savedPosition, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            guard self.player === avPlayer, self.player?.currentItem === item else { return }
            guard restored, abs(avPlayer.currentTime().seconds - savedPosition) <= 2 else {
              avPlayer.pause(); self.paused = true
              self.presentPlaybackInterruption("未能恢复上次位置，请返回后选择从头播放。原进度已保留。", failure: true)
              return
            }
            self.protectsUnverifiedResume = false
            self.elapsed = avPlayer.currentTime().seconds
          }
          if let qualityResume {
            self.paused = qualityResume.paused
            if qualityResume.paused { avPlayer.pause() } else { avPlayer.rate = self.playbackRate }
          }
          if let group = try? await item.asset.loadMediaSelectionGroup(for: .audible),
            self.player?.currentItem === item, !self.hasUserAudioChoice {
            let main = group.options.filter { $0.isPlayable && !AudioTrackPreference.isCommentary($0.displayName)
              && !$0.hasMediaCharacteristic(.describesVideoForAccessibility) }
            let original = main.first { AudioTrackPreference.isOriginal($0.displayName) }
            let selected = original ?? group.defaultOption.flatMap { main.contains($0) ? $0 : nil } ?? main.first
            if let selected { item.select(selected,in:group) }
          }
          // Subtitle language is independent of the main/original audio choice.
          if let group = try? await item.asset.loadMediaSelectionGroup(for: .legible),
            self.player?.currentItem === item, !self.hasUserSubtitleChoice
          {
            let options = group.options
            let index = SubtitlePreference.preferredIndex(languages: options.map { $0.extendedLanguageTag ?? $0.locale?.identifier }, titles: options.map(\.displayName))
            item.select(index.map { options[$0] }, in: group)
          }
          self.prepareAutomaticLocalSubtitle()
        default: break
        }
      }
    }
    timeObserver = avPlayer.addPeriodicTimeObserver(
      forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main
    ) { [weak self, weak avPlayer] time in
      Task { @MainActor in
        guard let self, let avPlayer, self.player === avPlayer else { return }
        let position = avPlayer.currentTime().seconds
        if position.isFinite, position >= 0 { self.elapsed = position }
        if let length = avPlayer.currentItem?.duration.seconds, length.isFinite, length > 0 { self.duration = length }
        if Int(self.elapsed) / 10 != self.lastSavedSecond / 10 {
          self.saveProgress()
          self.lastSavedSecond = Int(self.elapsed)
        }
      }
    }
    avPlayer.defaultRate = playbackRate
    if qualityResume == nil { avPlayer.playImmediately(atRate: playbackRate) }
    markPlaybackBenchmark("playRequested")
    playbackHealthTask = Task { @MainActor [weak self, weak avPlayer, weak avItem] in
      while !Task.isCancelled {
        do { try await Task.sleep(for: .seconds(1)) } catch { return }
        guard let self, let avPlayer, let avItem, self.player === avPlayer, avPlayer.currentItem === avItem else { return }
        self.observePlaybackProgress(player: avPlayer, item: avItem)
      }
    }
    playbackWatchdog = Task { @MainActor [weak self, weak avItem] in
      do { try await Task.sleep(for: .seconds(20)) } catch { return }
      guard let self, let avItem, self.player?.currentItem === avItem, avItem.status == .unknown
      else { return }
      avPlayer.pause()
      self.paused = true
      self.presentPlaybackInterruption("媒体读取超时。请检查来源连接、文件格式，以及 macOS 是否正在等待访问权限。", failure: true)
    }
  }
  private func observePlaybackProgress(player: AVPlayer, item: AVPlayerItem) {
    guard !playbackInterruptionIsFailure else { return }
    let position = player.currentTime().seconds
    let length = item.duration.seconds
    let ended = length.isFinite && length > 0 && position >= length - 0.5
    let stalled = playbackProgress.stalled(now: ProcessInfo.processInfo.systemUptime, position: position,
      wantsPlayback: !paused, ready: item.status == .readyToPlay, ended: ended)
    if stalled { presentPlaybackInterruption("播放暂时停住了，正在等待媒体。恢复后会自动继续；也可以重新播放。", failure: false) }
    else if playbackInterruption != nil { playbackInterruption = nil; showPlayerControls() }
  }
  private func presentPlaybackInterruption(_ message: String, failure: Bool) {
    playbackCompleted = false; episodeChoices = nil
    playbackTracks.close(notify: false)
    if playbackInterruption == nil { playbackInterruptionButton = 0 }
    playbackInterruptionIsFailure = failure
    playbackInterruption = message
    controlsTask?.cancel()
    playerControlsVisible = true
  }
  func playbackInterruptionCommand(_ index: Int) {
    guard playbackInterruption != nil else { return }
    if index == 0, let item = playbackRetryItem {
      // Resolve the original module reference again; never retain a signed URL for retry.
      let fromBeginning = playbackRetryFromBeginning
      stopPlayback()
      notice = nil
      play(item, fromBeginning: fromBeginning)
    } else { stopPlayback() }
  }
  func saveProgress() {
    guard !protectsUnverifiedResume else { return }
    if let id = currentMediaID, let source = playbackSourceID {
      let position = playbackCompleted && duration > 0 ? duration : (player?.currentTime().seconds ?? vlcEngine?.latest?.elapsed ?? elapsed)
      let length = playbackCompleted && duration > 0 ? duration : (player?.currentItem?.duration.seconds ?? duration)
      resumeStore.save(position, for: id, source: source, duration: length)
      continueWatching.saved()
    }
  }
  private func markPlaybackCompleted() {
    guard !playbackCompleted, playbackInterruption == nil, !protectsUnverifiedResume else { return }
    playbackCompleted = true; paused = true
    controlsTask?.cancel(); playerControlsVisible = false
    playbackTracks.close(notify: false); videoPresentation.close()
    if duration.isFinite && duration > 0 { elapsed = duration }
    saveProgress()
    let request = playbackRequestID
    Task { [weak self] in
      guard let self, self.playbackRequestID == request, self.playbackCompleted else { return }
      if self.loadingNextVideo { return }
      if self.hasNextVideo { self.stepVideo(1) }
      else { self.returnAfterPlayback() }
    }
  }
  private func returnAfterPlayback() {
    stopPlayback()
    closeHistoryDetail()
  }
  private func refreshNextEpisodePlan() {
    if let context = modulePlaybackContinuation { nextEpisodePlan = context.value.plan(currentID: context.currentID) }
    else { nextEpisodePlan = playbackRetryItem.flatMap { EpisodeContinuation.plan(current: $0, files: library) } }
    if !playerControlIndices.contains(playerButton) { playerButton = 1 }
  }
  func requestNextEpisode() {
    if modulePlaybackContinuation != nil { requestModuleContinuation(); return }
    guard let current = playbackRetryItem, let plan = EpisodeContinuation.plan(current: current, files: library) else {
      nextEpisodePlan = nil; notice = "后续剧集资料已变化，请返回选集。"; return
    }
    nextEpisodePlan = plan
    if plan.candidates.count == 1 && plan.message.isEmpty { openNextEpisode(plan.candidates[0]); return }
    controlsTask?.cancel(); episodeChoiceIndex = 0; episodeChoices = plan
  }
  func cancelCheckingModuleContinuation() {
    moduleContinuationGeneration = UUID(); moduleContinuationTask?.cancel(); moduleContinuationTask = nil
    checkingModuleContinuation = false; showPlayerControls()
  }
  private func requestModuleContinuation(expected: String? = nil) {
    guard !foregroundLoading, !preparingPlayback, !checkingModuleContinuation, let context = modulePlaybackContinuation else { return }
    guard let plugin = plugins.first(where: { $0.id == context.pluginID }), plugin.isAvailable,
      plugin.manifest.version == context.version, plugin.directory == context.directory,
      plugin.manifest.capabilities.contains("continuation") else { notice = "播放模块已发生变化，请返回重新选集。"; return }
    let attempt = UUID(); moduleContinuationGeneration = attempt
    let expectedTarget = expected ?? context.value.next?.reference
    episodeChoices = nil; controlsTask?.cancel(); checkingModuleContinuation = true
    moduleContinuationTask = Task {
      do {
        let data = try await PluginClient.execute(plugin, action: "continuation", input: ["reference": context.value.currentReference,
          "collection": context.value.collectionReference], sessionAccess: context.sessionAccess)
        guard !Task.isCancelled, moduleContinuationGeneration == attempt, modulePlaybackContinuation?.token == context.token,
          playbackRetryItem?.id == context.currentID, playbackSourceID == context.pluginID, playbackPresented else { return }
        let fresh = try JSONDecoder().decode(PluginContinuation.self, from: data).validated(manifest: plugin.manifest,
          currentID: context.currentID, expectedCurrent: context.value.currentReference, expectedCollection: context.value.collectionReference)
        modulePlaybackContinuation?.value = fresh; checkingModuleContinuation = false; refreshNextEpisodePlan()
        guard var next = fresh.next else { notice = "当前选集列表中已没有后续内容。"; return }
        if next.reference != expectedTarget {
          episodeChoices = fresh.plan(currentID: context.currentID, message: "选集列表已更新，请确认要继续的内容。")
          episodeChoiceIndex = 0; return
        }
        if modulePath.last?.reference != fresh.collectionReference { next.collectionReference = fresh.collectionReference }
        detail = next; detailAction = 0
        if let index = online.firstIndex(where: { $0.id == next.id }), modulePath.last?.reference == fresh.collectionReference {
          focus.select(row: 2 + index / gridColumns, column: index % gridColumns)
        }
        play(next, sessionAccessOverride: context.sessionAccess)
      } catch {
        guard !Task.isCancelled, moduleContinuationGeneration == attempt, modulePlaybackContinuation?.token == context.token else { return }
        checkingModuleContinuation = false; notice = "无法核对后续内容：" + error.localizedDescription
      }
    }
  }
  func dismissEpisodeChoices() { episodeChoices = nil; showPlayerControls() }
  func activateEpisodeChoice() {
    guard let plan = episodeChoices else { return }
    guard plan.candidates.indices.contains(episodeChoiceIndex) else { dismissEpisodeChoices(); return }
    openNextEpisode(plan.candidates[episodeChoiceIndex])
  }
  private func openNextEpisode(_ target: MediaItem) {
    if modulePlaybackContinuation != nil { requestModuleContinuation(expected: target.reference); return }
    refreshNextEpisodePlan()
    guard let fresh = nextEpisodePlan, let item = fresh.candidates.first(where: { $0.id == target.id }) else {
      episodeChoices = nil; notice = "下一集条目已变化，请返回选集。"; return
    }
    episodeChoices = nil
    detail = item; detailAction = 0
    if section == .library, libraryPath.count == 2,
      let identity = LibraryCatalog.seriesIdentity(item), libraryPath[0].id == "mtv:series:" + identity,
      let season = item.localMetadata?.season, let seasons = libraryCatalog.children[libraryPath[0].id],
      let index = seasons.firstIndex(where: { $0.id == libraryPath[0].id + "\nseason:\(season)" }) {
      libraryPath[1] = seasons[index]
      if libraryHistory.count == 2 { libraryHistory[1] = LibraryPosition(section: .library, query: "", row: 2 + index / 4, column: index % 4) }
    }
    if section == .library, let index = currentLibraryItems.firstIndex(where: { $0.id == item.id }) {
      focus.select(row: 2 + index / gridColumns, column: index % gridColumns)
    }
    play(item)
  }
  func stopPlayback(invalidateRequest: Bool = true) {
    nativeMedia.close()
    mediaSessionConsent = nil
    cancelPlayerScrub()
    automaticSubtitleTask?.cancel(); automaticSubtitleTask = nil
    playbackVolumeVisible = false
    playbackSpeedVisible = false
    moduleContinuationGeneration = UUID(); moduleContinuationTask?.cancel(); moduleContinuationTask = nil
    checkingModuleContinuation = false; modulePlaybackContinuation = nil
    if invalidateRequest, playbackResolveTask != nil { playbackResolveTask?.cancel(); playbackResolveTask = nil; loading = false }
    nextEpisodePlan = nil; episodeChoices = nil
    playbackTracks.close(notify: false)
    localSubtitleContext = nil
    hasUserSubtitleChoice = false
    hasUserAudioChoice = false
    playbackHealthTask?.cancel(); playbackHealthTask = nil
    playbackProgress.reset()
    playbackInterruption = nil; playbackInterruptionIsFailure = false; playbackRetryItem = nil; playbackRetryFromBeginning = false
    for resource in pendingRemoteResources { resource.cancel() }
    pendingRemoteResources = []
    remoteMedia?.cancel()
    remoteMedia = nil
    originalRemoteMedia?.cancel(); originalRemoteMedia = nil
    videoPresentation.reset()
    preflightGeneration = UUID()
    preflightTask?.cancel()
    preflightTask = nil
    preparationWatchdog?.cancel()
    preparationWatchdog = nil
    preparingPlayback = false
    if invalidateRequest { playbackRequestID = UUID(); pendingQualityResume = nil }
    playbackQualityVisible = false
    saveProgress()
    playbackCompleted = false
    player?.currentItem?.cancelPendingSeeks()
    benchmarkTimeObserver = nil
    player?.pause()
    if let engine = mpvEngine {
      engine.stop(); retiringMPV.append(engine)
      Task { [weak self] in await engine.waitUntilStopped(); self?.retiringMPV.removeAll { $0 === engine } }
    }
    mpvEngine = nil
    if let engine = vlcEngine {
      engine.stop()
      retiringVLC.append(engine)
      Task { [weak self] in
        await engine.waitUntilStopped()
        self?.retiringVLC.removeAll { $0 === engine }
      }
    }
    vlcEngine = nil
    playbackWatchdog?.cancel()
    playbackWatchdog = nil
    controlsTask?.cancel()
    controlsTask = nil
    playerControlsVisible = true
    if let timeObserver, let player { player.removeTimeObserver(timeObserver) }
    timeObserver = nil
    observer = nil
    if let playbackEndFailureObserver { NotificationCenter.default.removeObserver(playbackEndFailureObserver) }
    playbackEndFailureObserver = nil
    if let playbackCompletionObserver { NotificationCenter.default.removeObserver(playbackCompletionObserver) }
    playbackCompletionObserver = nil
    player = nil
    currentMediaID = nil
    continueWatching.end()
    playbackSourceID = nil
    protectsUnverifiedResume = false
    testVideoOutput = nil
  }
  func testDecodedFrame() -> CGImage? {
    guard let output = testVideoOutput, let player,
      let buffer = output.copyPixelBuffer(
        forItemTime: player.currentTime(), itemTimeForDisplay: nil)
    else { return nil }
    let image = CIImage(cvPixelBuffer: buffer)
    return CIContext().createCGImage(image, from: image.extent)
  }
  func smokeDecodedPixelsAvailable() -> Bool {
    guard CommandLine.arguments.contains("--ui-smoke"), let output = testVideoOutput, let player else { return false }
    return output.hasNewPixelBuffer(forItemTime: player.currentTime())
  }
  func smokeDecodedFrameObservation() -> PlaybackFrameObservation? {
    guard CommandLine.arguments.contains("--ui-smoke"), let output = testVideoOutput, let player else { return nil }
    let time = player.currentTime()
    let fresh = output.hasNewPixelBuffer(forItemTime: time)
    var shown = CMTime.invalid
    guard let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &shown) else { return nil }
    return PlaybackFrameObservation(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer),
      presentationTime: shown.seconds.isFinite ? shown.seconds : nil, fresh: fresh)
  }
  func playerCommand(_ index: Int) {
    if index == 1, !playerControlsVisible { playerButton = 1 }
    cancelPlayerScrub()
    if index == 11 { presentPlaybackQuality(); return }
    if index == 9, playbackPresented { controlsTask?.cancel(); playbackVolumeVisible = true; playbackVolumeSelection = 1; return }
    if index == 8, playbackPresented {
      controlsTask?.cancel(); playbackSpeedVisible = true
      playbackSpeedIndex = playbackRates.firstIndex(of: playbackRate) ?? 1
      return
    }
    if index == 7 || index == 10 { stepVideo(index == 7 ? 1 : -1); return }
    if (index == 3 || index == 4), playbackPresented {
      controlsTask?.cancel(); videoPresentation.close()
      openPlaybackTracks(index == 4 ? .subtitles : .audio)
      return
    }
    if index == 6, playbackPresented {
      playbackTracks.close(notify: false)
      controlsTask?.cancel()
      videoPresentation.present(systemEngine: player != nil)
      return
    }
    if let engine = mpvEngine {
      switch index {
      case 0: protectsUnverifiedResume = false; engine.seek(max(0,elapsed - 10))
      case 1: paused.toggle(); engine.pause(paused)
      case 2: protectsUnverifiedResume = false; engine.seek(duration > 0 ? min(max(0,duration - 0.25),elapsed + 10):elapsed + 10)
      default: stopPlayback()
      }
      showPlayerControls(); return
    }
    if let engine = vlcEngine {
      switch index {
      case 0: protectsUnverifiedResume = false; engine.seek(max(0, elapsed - 10))
      case 1:
        paused.toggle()
        engine.pause(paused)
      case 2: protectsUnverifiedResume = false; engine.seek(duration > 0 ? min(max(0, duration - 0.25), elapsed + 10) : elapsed + 10)
      default: stopPlayback()
      }
      showPlayerControls()
      return
    }
    guard let player else { return }
    switch index {
    case 0: player.seek(to: CMTime(seconds: max(0, elapsed - 10), preferredTimescale: 600))
    case 1:
      if duration > 0 && elapsed >= duration - 0.5 {
        player.seek(to: .zero)
        player.playImmediately(atRate: playbackRate)
        paused = false
      } else {
        if paused { player.playImmediately(atRate: playbackRate) } else { player.pause() }
        paused.toggle()
      }
    case 2:
      player.seek(
        to: CMTime(
          seconds: duration > 0 ? min(max(0, duration - 0.25), elapsed + 10) : elapsed + 10,
          preferredTimescale: 600))
    default: stopPlayback()
    }
    showPlayerControls()
  }
  @discardableResult func seekFromTimeline(_ requested: Double) -> Bool {
    guard playbackPresented, let target = PlaybackTimeline.target(requested, duration: duration) else { return false }
    protectsUnverifiedResume = false
    let ticket = UUID(); playerSeekTicket = ticket; playerSeekPreview = target
    if let engine = mpvEngine { engine.seek(target) }
    else if let engine = vlcEngine { engine.seek(target) }
    else if let player {
      player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak player] _ in
        Task { @MainActor in
          guard let self, let player, self.player === player else { return }
          // Opening a menu may cancel a preview ticket after the native seek
          // completed. Always reflect the current native clock; only the matching
          // ticket may clear its own preview. Never assign an old target value.
          let actual = player.currentTime().seconds
          if actual.isFinite { self.elapsed = actual }
          if self.playerSeekTicket == ticket { self.playerSeekPreview = nil; self.playerSeekTicket = nil }
        }
      }
    } else { cancelPlayerScrub(); return false }
    playerSeekPreviewTask?.cancel()
    playerSeekPreviewTask = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      guard let self, self.playerSeekTicket == ticket else { return }
      self.playerSeekPreview = nil; self.playerSeekTicket = nil
    }
    showPlayerControls()
    return true
  }
  func showPlayerControls() {
    guard playbackPresented else { return }
    controlsTask?.cancel()
    playerControlsVisible = true
    guard !paused, !playbackCompleted, !playerTimelineFocused, playerScrub == nil, playbackInterruption == nil, !playbackTracks.isPresented, !playbackSpeedVisible, !playbackVolumeVisible, !playbackQualityVisible else { return }
    controlsTask = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      guard let self, self.playbackPresented, !self.paused, self.playerScrub == nil, !self.videoPresentation.isPresented, !self.playbackTracks.isPresented else { return }
      self.playerControlsVisible = false
    }
  }
  func selectEngine(_ choice: PlaybackEngineChoice) {
    guard CommandLine.arguments.contains("--ui-smoke") else { return }
    if preparingPlayback { stopPlayback() }
    guard choice != .vlc || VLCPlaybackEngine.isAvailable else {
      notice = "此构建未包含通用引擎，尚不能选择。"
      return
    }
    guard choice != .mpv || MPVPlaybackEngine.isAvailable else { notice = "此构建尚未包含MPV播放组件"; return }
    preferredEngine = choice
    enginePickerVisible = false
    audioOutputVisible = false
    if !CommandLine.arguments.contains("--ui-smoke") {
      UserDefaults.standard.set(choice.rawValue, forKey: "playbackEngine")
    }
  }
  func prepareForTermination() -> Bool {
    libraryMaintenance.stop()
    watchlist.cancelEnrichment()
    sourceSwitchID = UUID()
    networkPath.stop()
    networkRecovery.deactivate()
    libraryCommitTask?.cancel()
    sourceNeedsSetup = false
    sourceSetup.close()
    savedSources.close()
    pluginManager.close(); pluginFolders.close()
    libraryOverview.close()
    libraryBrowser.close()
    libraryScanID = UUID()
    libraryScanWorker?.cancel()
    libraryScanTimeout?.cancel()
    localFolders.close()
    automaticMetadata.close()
    metadata.close()
    smb.close()
    login.close(reload: false)
    loadTask?.cancel()
    moduleGeneration = UUID()
    playbackRequestID = UUID()
    saveProgress()
    stopPlayback()
    return !retiringVLC.isEmpty || !retiringMPV.isEmpty || savingSource || pluginManager.hasPendingMutation || continueWatching.recoveryBusy
  }
  func waitForPlaybackShutdown() async {
    await continueWatching.waitForRecovery()
    await pluginManager.waitForPendingChanges()
    await savedSources.waitForPendingChanges()
    await smb.waitForPendingSaves()
    await sourceSaveTask?.value
    let engines = retiringVLC
    for engine in engines { await engine.waitUntilStopped() }
    let mpvEngines = retiringMPV
    for engine in mpvEngines { await engine.waitUntilStopped() }
    let reports = await SMBMountClient.retire(activeSMBShares, deadline: 2)
    let removed = Set(reports.filter { $0.outcome == "removed" }.map(\.mountID))
    activeSMBShares.removeAll { removed.contains($0.mount.lastPathComponent) }
    if !reports.isEmpty {
      launchLog.notice("SMB quit retirement; requested=\(reports.count) removed=\(removed.count)")
    }
    let preservesPrivateScope = CommandLine.arguments.contains("--ui-smoke") && CommandLine.arguments.contains("--history-test-scope")
      && (CommandLine.arguments.contains("--history-cold-write") || CommandLine.arguments.contains("--watchlist-cold-write"))
    if !preservesPrivateScope {
      resumeStore.removeTestDomain()
    }
  }
  private func beginMPVPlayback(url: URL,item: MediaItem,fromBeginning: Bool,subtitleRestart: SubtitlePlaybackRestart? = nil, original: OriginalRemoteMedia? = nil) {
    guard MPVPlaybackEngine.isAvailable, url.isFileURL || original?.url == url else { notice = "此片源需要本地MPV播放组件"; return }
    stopPlayback(invalidateRequest:false)
    originalRemoteMedia = original
    localSubtitleContext = url.isFileURL ? makeSubtitleContext(url:url,item:item) : nil
    nextEpisodePlan = EpisodeContinuation.plan(current:item,files:library)
    playbackTitle = item.title; playbackState = "正在打开影片…"
    currentMediaID = item.id; playbackSourceID = item.source
    playbackRetryItem = item; playbackRetryFromBeginning = fromBeginning
    let saved = subtitleRestart?.position ?? (fromBeginning ? 0:(resumeStore.record(for:item.id,source:item.source)?.resumablePosition ?? 0))
    protectsUnverifiedResume = saved > 0; elapsed = 0; duration = 0; paused = subtitleRestart?.paused ?? false
    hasUserSubtitleChoice = subtitleRestart?.userSubtitleChoice == true
    playerButton = 1; playerControlsVisible = true; lastSavedSecond = 0
    beginHistoryForPlayback(item)
    let engine = MPVPlaybackEngine()
    var restored = saved == 0
    var controlsReady = false
    engine.onUpdate = { [weak self,weak engine] value in
      guard let self,let engine,self.mpvEngine === engine else { return }
      self.elapsed = value.elapsed
      if value.duration > 0 { self.duration = value.duration }
      self.paused = value.paused || value.ended
      if value.buffering, self.playbackBenchmark?.milestonesMS["renderReady"] != nil { self.markPlaybackBenchmark("firstRebuffer") }
      if value.vo == "gpu-next", value.frames > 0, value.width > 0, !value.seeking, !value.buffering {
        self.markPlaybackBenchmark("nativeVideoParametersReady")
        if !value.paused && value.elapsed > 0 { self.markPlaybackBenchmark("timelinePlaying") }
        if !controlsReady { controlsReady = true; self.showPlayerControls() }
        if subtitleRestart == nil { self.prepareAutomaticLocalSubtitle() }
        self.playbackState = value.matrix == "dolbyvision" ? "杜比兼容播放 · MPV":"MPV播放"
        if !restored {
          restored = true
          if (subtitleRestart == nil && (value.duration <= 30 || saved >= value.duration - 15)) || abs(value.elapsed - saved) > 2 {
            engine.pause(true)
            self.presentPlaybackInterruption("未能准确恢复上次位置，原进度已保留。可选择从头播放。",failure:true)
          } else { self.protectsUnverifiedResume = false }
        }
      }
      if value.ended { self.markPlaybackCompleted() }
      if Int(value.elapsed) / 10 != self.lastSavedSecond / 10 {
        self.saveProgress(); self.lastSavedSecond = Int(value.elapsed)
      }
    }
    engine.onError = { [weak self,weak engine] message in
      guard let self,let engine,self.mpvEngine === engine else { return }
      self.stopPlayback(); self.notice = "影片未能打开：" + message
    }
    engine.onClose = { [weak self,weak engine] in
      if let self,let engine,self.mpvEngine === engine { self.stopPlayback() }
    }
    mpvEngine = engine
    markPlaybackBenchmark("playRequested")
    engine.start(url:url,position:saved,rate:playbackRate,volume:effectivePlaybackVolume,model:self,
      initiallyPaused:subtitleRestart?.paused ?? false,initialSubtitle:subtitleRestart?.subtitle,ownedLoopbackURL:original?.url)
  }
  private func beginVLCPlayback(url: URL, item: MediaItem, fromBeginning: Bool = false, containerPlan: VLCContainerPlan = .standard, subtitleRestart: SubtitlePlaybackRestart? = nil, moduleContinuation: ModulePlaybackContinuation? = nil) {
    stopPlayback(invalidateRequest: false)
    localSubtitleContext = makeSubtitleContext(url: url, item: item)
    modulePlaybackContinuation = moduleContinuation
    nextEpisodePlan = moduleContinuation?.value.plan(currentID: item.id) ?? EpisodeContinuation.plan(current: item, files: library)
    playbackTitle = item.title
    playbackState = "正在打开通用播放引擎…"
    currentMediaID = item.id
    lastSavedSecond = 0
    let savedPosition = subtitleRestart?.position ?? (fromBeginning ? 0 : (resumeStore.record(for: item.id, source: item.source)?.resumablePosition ?? 0))
    playbackSourceID = item.source
    elapsed = 0
    duration = 0
    paused = false
    playerButton = 1
    playerControlsVisible = true
    let engine = VLCPlaybackEngine(startPosition: savedPosition, containerPlan: containerPlan, subtitle: subtitleRestart?.subtitle,
      audioAccess: localSubtitleContext?.access, rate: playbackRate, automaticSubtitles: subtitleRestart?.userSubtitleChoice != true)
    hasUserSubtitleChoice = subtitleRestart?.userSubtitleChoice == true
    engine.initialVolume = effectivePlaybackVolume
    let initialSelectionReason = playbackSelectionReason
    engine.onAudioStrategy = { [weak self, weak engine] summary in
      guard let self, let engine, self.vlcEngine === engine, !summary.isEmpty else { return }
      self.playbackSelectionReason = initialSelectionReason.replacingOccurrences(of: containerPlan.reason, with: summary)
    }
    protectsUnverifiedResume = savedPosition > 0
    playbackRetryItem = item
    playbackRetryFromBeginning = fromBeginning
    beginHistoryForPlayback(item)
    var ready = false
    var pauseAfterRestart = subtitleRestart?.paused == true
    engine.onUpdate = { [weak self, weak engine] value in
      guard let self, let engine, self.vlcEngine === engine else { return }
      self.elapsed = value.elapsed
      if value.duration > 0 { self.duration = value.duration }
      if value.state == 7 {
        self.presentPlaybackInterruption("此片源暂时无法播放。可以重新播放，或返回选择其他内容。", failure: true)
        self.paused = true
        self.showPlayerControls()
      }
      if value.state == 3 && !ready {
        ready = true
        self.prepareAutomaticLocalSubtitle()
        self.playbackState = "VLC 通用播放 · HDR / 杜比输出未验证"
        self.showPlayerControls()
      }
      if self.protectsUnverifiedResume, self.playbackInterruption == nil, value.duration > 0 {
        if subtitleRestart == nil && (value.duration <= 30 || savedPosition >= value.duration - 15) {
          engine.pause(true)
          self.presentPlaybackInterruption("片源长度已变化，无法恢复上次位置。请返回后选择从头播放。", failure: true)
        } else if value.state == 3, value.elapsed > 0, value.displayedPictures > 0 {
          if abs(value.elapsed - savedPosition) > 2 {
            engine.pause(true)
            self.presentPlaybackInterruption("播放器未能准确恢复上次位置，已暂停并保留原进度。请返回后选择从头播放，或手动选择其他播放引擎。", failure: true)
          } else { self.protectsUnverifiedResume = false }
        }
      }
      if value.state == 3 && self.playbackInterruption == nil { self.paused = false }
      if value.state == 4 || value.state == 6 { self.paused = true }
      if value.state == 6 { self.markPlaybackCompleted() }
      if pauseAfterRestart, value.state == 3, value.displayedPictures > 0, !self.protectsUnverifiedResume {
        pauseAfterRestart = false; engine.pause(true); self.paused = true
      }
      if Int(value.elapsed) / 10 != self.lastSavedSecond / 10 {
        self.saveProgress()
        self.lastSavedSecond = Int(value.elapsed)
      }
    }
    engine.onError = { [weak self, weak engine] message in
      guard let self, let engine, self.vlcEngine === engine else { return }
      self.presentPlaybackInterruption("播放已中断：\(message)", failure: true)
      self.paused = true
      self.showPlayerControls()
    }
    vlcEngine = engine
    engine.start(url: url)
  }
}

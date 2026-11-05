import AVKit
import AppKit
import MTVCore
import SwiftUI

private let ink = TVPalette.background
private let accent = Color.primary.opacity(0.86)

@MainActor struct Artwork: View {
  @ObservedObject private var refresh: ArtworkRefresh
  let primaryAddresses: [String]
  let fallbackAddress: String?
  let fallbackBlur: CGFloat
  let placeholder: String
  var videoURL: URL? = nil
  @State private var loadedImage: NSImage?
  @State private var loadedFromFallback = false
  init(address: String?, fallbackAddress: String? = nil, fallbackBlur: CGFloat = 0, refresh: ArtworkRefresh? = nil, placeholder: String = "film", videoURL: URL? = nil) {
    self.init(primaryAddresses: address.map { [$0] } ?? [], fallbackAddress: fallbackAddress, fallbackBlur: fallbackBlur, refresh: refresh, placeholder: placeholder)
    self.videoURL = videoURL
  }
  init(primaryAddresses: [String], fallbackAddress: String? = nil, fallbackBlur: CGFloat = 0, refresh: ArtworkRefresh? = nil, placeholder: String = "film") {
    self.primaryAddresses = primaryAddresses; self.fallbackAddress = fallbackAddress; self.fallbackBlur = fallbackBlur; self.placeholder = placeholder
    _refresh = ObservedObject(wrappedValue: refresh ?? .shared)
  }
  private struct Request: Hashable { let url: URL; let revision: UInt64; let access: ArtworkFileAccess; let isFallback: Bool }
  private var requests: [Request] {
    var seen = Set<URL>()
    let values = primaryAddresses.map { ($0, false) } + (fallbackAddress.map { [($0, true)] } ?? [])
    return values.compactMap { value, fallback in
      guard let url = URL(string: value), seen.insert(url).inserted else { return nil }
      return Request(url: url, revision: refresh.version(for: url), access: refresh.access(for: url), isFallback: fallback)
    }
  }
  private var videoRequest: VideoThumbnail.Request? {
    guard let videoURL, videoURL.isFileURL else { return nil }
    return .init(url: videoURL, access: refresh.access(for: videoURL), revision: refresh.version(for: videoURL))
  }
  private struct ArtworkTask: Hashable { let images: [Request]; let video: VideoThumbnail.Request? }
  var body: some View {
    GeometryReader { proxy in
      ZStack {
        Color(white: 0.095)
        if let loadedImage {
          Image(nsImage: loadedImage).resizable().scaledToFill()
            .blur(radius: loadedFromFallback ? fallbackBlur : 0)
        } else {
          Image(systemName: placeholder).font(.system(size: 40)).foregroundStyle(.white.opacity(0.2))
        }
      }.frame(width: proxy.size.width, height: proxy.size.height).clipped()
    }.task(id: ArtworkTask(images: requests, video: videoRequest)) {
      loadedImage = nil
      loadedFromFallback = false
      let candidates = requests, video = videoRequest
      for candidate in candidates {
        // An unavailable image may use the declared fallback. A denied primary
        // must not use another address to evade withdrawal of its share access.
        guard candidate.access != .denied else { return }
        let image = await ArtworkCache.shared.image(for: candidate.url, revision: candidate.revision, access: candidate.access)
        guard !Task.isCancelled, requests == candidates else { return }
        if let image { loadedFromFallback = candidate.isFallback; loadedImage = image; return }
      }
      if let video, let image = await VideoThumbnail.image(for: video),
        !Task.isCancelled, requests == candidates, videoRequest == video {
        loadedImage = image
      }
    }
  }
}

struct TVButton<Content: View>: View {
  @Environment(\.colorSchemeContrast) private var contrast
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let selected: Bool
  var showsFocusRing = true
  var subtleFocus = false
  let action: () -> Void
  let hover: () -> Void
  @ViewBuilder let content: () -> Content
  var body: some View {
    Button(action: action) { content().contentShape(Rectangle()) }
      .buttonStyle(.plain).focusable(false)
      .background(
        selected && showsFocusRing ? Color.primary.opacity(contrast == .increased ? 0.32 : 0.18) : .clear,
        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
      )
      .brightness(selected && showsFocusRing && subtleFocus ? 0.08 : 0)
      .scaleEffect(selected && showsFocusRing && subtleFocus && !reduceMotion ? 1.025 : 1)
      .shadow(color: .black.opacity(selected && showsFocusRing ? 0.25 : 0), radius: 12, y: 6)
      .animation(
        reduceMotion ? nil : (subtleFocus ? .timingCurve(0.22, 0.8, 0.25, 1, duration: 0.18) : .spring(response: 0.32, dampingFraction: 0.82)), value: selected
      )
      .tvPointerFocus { hover() }
  }
}

struct RootView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.colorScheme) private var systemColorScheme
  @ObservedObject var model: AppModel
  var body: some View {
    GeometryReader { geometry in
      let scale = max(1, min(geometry.size.width / 1280, geometry.size.height / 720))
      let canvas = CGSize(width: geometry.size.width / scale, height: geometry.size.height / scale)
      ZStack(alignment: .top) {
        ink.ignoresSafeArea()
        VStack(spacing: 0) {
          navigation.padding(.horizontal, 64).padding(.top, 24).padding(.bottom, 20)
            .background(ink)
          if let error = model.sourceError, model.section != .settings {
            Label(error, systemImage: "exclamationmark.circle")
              .font(.system(size: 16, weight: .medium)).foregroundStyle(.orange).lineLimit(2)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 64).padding(.bottom, 14).background(ink)
          }
          if model.libraryNeedsAttention && (model.section == .home || model.section == .library) {
            Label(model.libraryStatus, systemImage: "externaldrive.badge.exclamationmark")
              .font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
              .frame(maxWidth: .infinity, alignment: .leading)
              .padding(.horizontal, 64).padding(.bottom, 14).background(ink)
          }
          ScrollViewReader { scroll in
            ScrollView {
              VStack(alignment: .leading, spacing: model.section == .settings ? 24 : 40) {
                if model.section == .home {
                  hero.foregroundStyle(.white).frame(height: max(390, min(560, canvas.height * 0.54)))
                    .padding(.horizontal, -64)
                  appRow
                  if !model.continueWatching.entries.isEmpty { ContinueWatchingRow(model: model) }
                  if !model.watchlist.entries.isEmpty { SavedContentShelf(model: model, shelf: .watchlist) }
                  if let error = model.watchlist.error {
                    Label(L("待看片单暂不可用：") + error, systemImage: "exclamationmark.circle")
                      .font(.system(size: 16)).foregroundStyle(.secondary)
                  }
                  if let error = model.continueWatching.error {
                    Label(L("继续观看暂不可用：") + error, systemImage: "exclamationmark.circle")
                      .font(.system(size: 16)).foregroundStyle(.secondary)
                  }
                } else {
                  sectionHeading.padding(.top, model.section == .settings ? 0 : 30)
                }
                if model.section == .home || model.section == .library || model.section == .bilibili
                {
                  mediaGrid(width: canvas.width)
                } else if model.section == .extensions {
                  extensions
                } else {
                  settings
                }
              }.padding(.horizontal, 64).padding(.bottom, 70).id("top")
            }
            .overlayPreferenceValue(MediaTitleAnchorKey.self) { anchors in
              MediaFocusObserver(model: model, anchors: anchors).allowsHitTesting(false)
            }
            .onChange(of: canvas) { _, _ in
              guard model.section != .settings, model.focus.row >= model.mediaFocusOffset else { return }
              scroll.scrollTo("row-\(model.focus.row)", anchor: .center)
            }
            .onChange(of: model.focus.row) { _, row in
              guard model.section != .settings else { return }
              withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) {
                let showHeading = row == 0 || (model.hasModuleSubnavigation && row < model.mediaFocusOffset)
                scroll.scrollTo(showHeading ? "top" : "row-\(row)", anchor: showHeading || row == 1 ? .top : .center)
              }
            }
            .onChange(of: model.section) { _, _ in
              if model.section == .settings { scroll.scrollTo("top", anchor: .top); return }
              let row = model.focus.row
              scroll.scrollTo(row == 0 ? "top" : "row-\(row)", anchor: row <= 1 ? .top : .center)
            }
          }
        }
        if model.loading {
          HStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(L("正在加载")).font(.system(size: 14))
          }
          .padding(16).background(.ultraThinMaterial, in: Capsule()).frame(
            maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing
          ).padding(30)
        }
        if let detail = model.detail, !model.playbackPresented {
          DetailView(model: model, item: detail).foregroundStyle(.white).preferredColorScheme(.dark)
        }
        if model.playbackPresented, model.mpvEngine == nil { PlayerScreen(model: model).foregroundStyle(.white).environment(\.colorScheme, .dark).preferredColorScheme(.dark) }
        if model.playbackQualityVisible { PlaybackQualityPanel(model: model) }
        if model.playbackSpeedVisible { PlaybackSpeedPanel(model: model).preferredColorScheme(.dark) }
        if model.playbackVolumeVisible { PlaybackVolumePanel(model: model).preferredColorScheme(.dark) }
        if model.appearanceVisible { TVAppearancePanel(model: model) }
        if model.preparingPlayback || model.loadingNextVideo {
          ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
              ProgressView().controlSize(.large)
              Text(L("正在加载")).font(.system(size: 17)).foregroundStyle(.secondary)
            }
            .environment(\.colorScheme, .dark)
          }
        }
        if model.information.isPresented { AboutMacTVPanel(controller: model.information) }
        if model.setupGuideVisible { SetupGuide(model:model) }
        if model.sourceSetup.isPresented { SourceSetupPanel(controller: model.sourceSetup, error: model.sourceError) }
        if model.savedSources.isPresented { SavedSourcesPanel(controller: model.savedSources) }
        if model.libraryOverview.isPresented { LibraryOverviewPanel(controller: model.libraryOverview,
          refresh: { model.presentLibraryOverview() }, search: { model.showOverviewKeyboard() }, clear: { model.searchLibraryOverview("") }) }
        if model.smb.isPresented { SMBPanel(controller: model.smb) }
        if model.localFolders.isPresented { LocalFolderPanel(controller: model.localFolders) }
        if model.navigationCustomizationVisible { TVNavigationPanel(model: model) }
        if model.pluginManager.isPresented { PluginManagerPanel(controller: model.pluginManager) }
        if model.pluginFolders.isPresented { LocalFolderPanel(controller: model.pluginFolders) }
        if model.metadata.isPresented { MetadataPanel(controller: model.metadata) }
        if model.automaticMetadata.isPresented {
          AutomaticMetadataPanel(controller: model.automaticMetadata)
        }
        if model.keyboardVisible { KeyboardScreen(model: model) }
        if model.accountSettingsVisible && !model.login.isPresented { TVAccounts(model: model) }
        if model.login.isPresented { LoginPanel(controller: model.login) }
        if model.mediaSessionConsent != nil { MediaSessionConsentPanel(model: model) }
        if model.enginePickerVisible { PlaybackEnginePicker(model: model) }
        if model.audioOutputVisible { AudioOutputPanel(model: model) }
        if model.libraryBrowser.isPresented { LibraryBrowsePanel(controller: model.libraryBrowser) }
        if model.videoPresentation.isPresented { VideoPresentationPanel(controller: model.videoPresentation) }
        if model.playbackTracks.isPresented { PlaybackTracksPanel(controller: model.playbackTracks) }
        if model.episodeChoices != nil { EpisodeContinuationPanel(model: model) }
        if model.checkingModuleContinuation {
          ZStack {
            TVPopupBackdrop()
            VStack(spacing: 28) {
              ProgressView("正在核对" + model.checkingContinuationLabel + "…")
              TVButton(selected: true, action: { model.cancelCheckingModuleContinuation() }, hover: {}) {
                Text(L("返回播放")).font(.system(size: 20, weight: .semibold)).frame(width: 220, height: 64)
              }
            }.padding(40).frame(width: 520).tvPopupSurface()
          }
        }
        if model.continueWatching.menuID != nil { ContinueWatchingMenu(controller: model.continueWatching) }
        if model.watchlist.menuID != nil { WatchlistMenu(controller: model.watchlist) }
        if model.continueWatching.recoveryPresented { ContinueWatchingRecoveryPanel(controller: model.continueWatching) }
        if let notice = model.notice { noticeOverlay(notice) }
        if model.nativeMedia.isPresented { NativeMediaPanel(controller:model.nativeMedia) }
      }.foregroundStyle(.primary).preferredColorScheme(model.appearance.scheme)
        .environment(\.colorScheme, model.appearance.scheme ?? systemColorScheme)
        .environment(\.tvGlassEnabled, model.glassEnabled)
        .frame(width: canvas.width, height: canvas.height)
        .scaleEffect(scale, anchor: .topLeading)
    }.frame(minWidth: 1100, minHeight: 700)
  }
  var navigation: some View {
    HStack(spacing: 0) {
      HStack(spacing: 8) {
        Text(AppBrand.name).font(.system(size: 30, weight: .bold, design: .rounded)).tracking(-1.5)
      }.frame(width: 100, alignment: .leading)
      Spacer()
      HStack(spacing: 3) {
        ForEach(Array(model.visibleNavigationTabs.enumerated()), id: \.offset) { index, section in
          let focused = model.focus.row == 0 && model.focus.column == index
          Button {
            model.focusNavigation(at: index)
          } label: {
            Text(section.title).font(.system(size: 17, weight: .semibold))
              .foregroundStyle(
                focused ? Color(nsColor: .textBackgroundColor) : Color.primary.opacity(model.activeNavigationTab == section ? 1 : 0.66)
              )
              .padding(.horizontal, 23).padding(.vertical, 13)
              .background(
                focused ? Color.primary : Color.primary.opacity(model.activeNavigationTab == section ? 0.12 : 0),
                in: Capsule())
          }.buttonStyle(.plain).focusable(false).tvPointerFocus { model.focusNavigation(at: index) }
        }
      }.padding(6).tvGlass(radius: 40)
        
        .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
      Spacer()
      Text(Date(), style: .time).font(.system(size: 19, weight: .medium)).monospacedDigit().foregroundStyle(
        .secondary
      ).frame(width: 100, alignment: .trailing)
    }.id("row-0")
  }
  var hero: some View {
    let ink = Color.black
    return ZStack(alignment: .leading) {
      if let poster = model.selectedHero?.poster, let url = URL(string: poster) {
        Artwork(
          address: url.isFileURL
            ? url.deletingLastPathComponent().appendingPathComponent("fanart.jpg")
              .absoluteString : poster)
      }
      LinearGradient(
        stops: [
          .init(color: .black.opacity(0.72), location: 0),
          .init(color: .black.opacity(0.2), location: 0.5), .init(color: .clear, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
      LinearGradient(
        stops: [
          .init(color: .black.opacity(0.38), location: 0), .init(color: .clear, location: 0.35),
          .init(color: ink.opacity(0.15), location: 0.65), .init(color: ink, location: 1),
        ], startPoint: .top, endPoint: .bottom)
      VStack(alignment: .leading, spacing: 20) {
        Spacer(minLength: 0)
        Text(L("精选推荐")).font(.system(size: 15, weight: .semibold)).foregroundStyle(
          .white.opacity(0.75))
        Text(model.selectedHero?.title ?? L("属于你的大银幕。"))
          .font(.system(size: 58, weight: .bold)).tracking(-2).lineSpacing(2).lineLimit(2)
          .shadow(color: .black.opacity(0.35), radius: 15, y: 4)
        Text(model.selectedHero?.overview ?? L("用遥控器发现影片，用原生体验连接你的内容。"))
          .font(.system(size: 18, weight: .medium)).foregroundStyle(.white.opacity(0.8))
          .lineSpacing(5).lineLimit(2).fixedSize(horizontal: false, vertical: true).frame(maxWidth: 570, alignment: .leading)
        HStack(spacing: 12) {
          Button {
            if let item = model.selectedHero { model.activateCard(item) }
            else if model.needsSMBReconnect { model.reconnectSMB() }
            else { model.presentSourceSetup() }
          } label: {
            Label(
              LT(model.selectedHero == nil ? (model.needsSMBReconnect ? "连接 NAS" : "添加影片来源") : (model.selectedHero?.isLibraryCollection == true ? "浏览剧集" : "播放影片")),
              systemImage: "play.fill"
            ).font(.system(size: 17, weight: .semibold))
              .foregroundStyle(.black).padding(.horizontal, 28).padding(.vertical, 16).background(
                .white, in: Capsule())
          }.buttonStyle(.plain).focusable(false)
            .scaleEffect(model.focus.row == 1 && !reduceMotion ? 1.05 : 1)
            .shadow(color: .white.opacity(model.focus.row == 1 ? 0.22 : 0), radius: 16)
            .tvPointerFocus { model.focus.select(row: 1, column: 0) }
          Text(L("你的影片库")).font(.system(size: 14, weight: .medium)).foregroundStyle(
            .white.opacity(0.6))
        }.padding(.top, 4)
      }.padding(.leading, 64).padding(.bottom, 28).frame(
        maxWidth: 800, maxHeight: .infinity, alignment: .bottomLeading)
    }.clipped().id("row-1")
  }
  var appRow: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text(L("你的应用")).font(.system(size: 24, weight: .bold)).tracking(-0.5)
      ScrollViewReader { shelf in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(alignment: .top, spacing: 24) {
            appCard(
              0, title: L("影片库"), symbol: "play.rectangle.on.rectangle.fill",
              colors: [.blue, .indigo]
            ) { model.navigate(.library) }
            .id("home-module-0")
            ForEach(Array(model.homePlugins.enumerated()), id: \.element.id) { index, plugin in
              pluginCard(plugin, column: index + 1).id("home-module-\(index + 1)")
            }
            appCard(
              model.homePlugins.count + 1, title: L("搜索"),
              symbol: "magnifyingglass", colors: [.gray, .black]
            ) { model.showKeyboard() }
            .id("home-module-\(model.homePlugins.count + 1)")
          }.padding(.vertical, 8).padding(.horizontal, 6)
        }.padding(.horizontal, -6)
          .onChange(of: model.focus.column) { _, column in
            if model.focus.row == 2 {
              withAnimation(.easeInOut(duration: 0.2)) {
                shelf.scrollTo("home-module-\(column)", anchor: .center)
              }
            }
          }
          .onChange(of: model.focus.row) { _, row in
            if row == 2 { shelf.scrollTo("home-module-\(model.focus.column)", anchor: .center) }
          }
      }
    }.id("row-2")
  }
  func pluginCard(_ plugin: PluginRecord, column: Int) -> some View {
    let presentation = plugin.manifest.presentation
    let tint: Color =
      switch presentation?.tint {
      case "pink": .pink
      case "cyan": .cyan
      case "blue": .blue
      case "purple": .purple
      default: .indigo
      }
    return appCard(
      column, title: plugin.title,
      symbol: presentation?.symbol ?? "puzzlepiece.extension", colors: [tint, .black], pluginID: plugin.id, unavailable: !plugin.isAvailable
    ) { model.openModule(plugin) }
  }
  func appCard(
    _ column: Int, title: String, symbol: String, colors: [Color], pluginID: String? = nil, unavailable: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    let selected = model.focus.row == (model.section == .home ? 2 : 1) && model.focus.column == column
    return TVButton(
      selected: selected, showsFocusRing: false,
      action: action,
      hover: { model.focus.select(row: model.section == .home ? 2 : 1, column: column) }
    ) {
      VStack(spacing: 13) {
        ZStack {
          RoundedRectangle(cornerRadius: 22).fill(
            LinearGradient(
              colors: colors.map { $0.opacity(0.65) }, startPoint: .topLeading,
              endPoint: .bottomTrailing))
          RoundedRectangle(cornerRadius: 22).fill(
            LinearGradient(
              colors: [.white.opacity(0.15), .clear, .black.opacity(0.2)], startPoint: .top,
              endPoint: .bottom))
          if let pluginID, let icon = BrandIcon.image(pluginID) {
            Image(nsImage: icon).resizable().interpolation(.high).scaledToFit().frame(width: 76, height: 76)
          } else {
            Image(systemName: symbol).font(.system(size: 34, weight: .medium))
          }
        }
        .frame(height: 124)
        .brightness(selected ? 0.16 : 0)
        .scaleEffect(selected && !reduceMotion ? 1.035 : 1)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: selected)
        .shadow(color: .black.opacity(selected ? 0.5 : 0), radius: 18, y: 8)
        Text(title).font(.system(size: 16, weight: .semibold))
        if unavailable {
          Text(L("开发中")).font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }.padding(5).padding(.bottom, 8).frame(maxWidth: .infinity, alignment: .top)
    }.frame(width: 220)
  }
  private var moduleUtilities: some View {
    HStack(spacing: 12) {
      moduleUtility(model.modulePrimaryTitle,
        symbol: !model.modulePath.isEmpty ? "arrow.uturn.backward" : model.moduleSupportsSearch ? "magnifyingglass" : "arrow.clockwise", column: 0) {
        model.modulePrimaryAction()
      }
      if model.moduleSupportsLookup {
        moduleUtility(L("打开视频编号"), symbol: "link", column: model.moduleLookupColumn) {
          model.showModuleLookup()
        }
      }
      if let plugin = model.activePlugin, plugin.manifest.authentication != nil {
        let status = model.login.accountErrors[plugin.id] != nil ? L("登录异常")
          : model.login.savedSessions.contains(plugin.id) ? L("已登录") : L("未登录")
        moduleUtility(status, symbol: "person.crop.circle", column: model.moduleAccountColumn) {
          model.showLogin(plugin)
        }
      }
    }
  }
  private func moduleUtility(_ title: String, symbol: String, column: Int, action: @escaping () -> Void) -> some View {
    TVButton(selected: model.focus.row == model.moduleToolbarRow && model.focus.column == column,
      action: action, hover: { model.focus.select(row: model.moduleToolbarRow, column: column) }) {
      Label(title, systemImage: symbol).font(.system(size: 16, weight: .medium))
        .lineLimit(1).padding(.horizontal, 14).padding(.vertical, 9)
    }
  }
  var sectionHeading: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(spacing: 16) {
      if model.section == .bilibili, let id = model.activePlugin?.id, let icon = BrandIcon.image(id) {
        Image(nsImage: icon).resizable().scaledToFit().frame(width: 44, height: 44)
      }
      Text(
        model.section == .bilibili
          ? model.moduleTitle
          : (model.section == .library
            ? model.libraryPath.last?.title ?? model.section.rawValue : model.section.rawValue)
      ).font(
        .system(size: 44, weight: .bold)
      ).tracking(-1.5)
        if model.hasModuleSubnavigation {
          Spacer(minLength: 20)
          moduleUtilities
        }
      }
      if model.hasBilibiliTabs {
        BilibiliNavigation(model: model)
      }
      if model.section == .library || (model.section == .bilibili && !model.hasModuleSubnavigation) {
        HStack(spacing: 18) {
          TVButton(
            selected: model.focus.row == model.moduleToolbarRow && model.focus.column == 0,
            action: {
              if model.section == .bilibili {
                model.modulePrimaryAction()
              } else {
                if !model.hasLibrarySource { model.presentSourceSetup() } else { model.showKeyboard() }
              }
            },
            hover: { model.focus.select(row: model.moduleToolbarRow, column: 0) }
          ) {
            Label(
              model.section == .bilibili
                ? model.modulePrimaryTitle : (!model.hasLibrarySource ? "添加影片来源" : (model.search.isEmpty ? "搜索影片…" : model.search)),
              systemImage: model.section == .bilibili && !model.modulePath.isEmpty
                ? "arrow.uturn.backward"
                : (model.section == .bilibili && !model.moduleSupportsSearch
                  ? "arrow.clockwise" : "magnifyingglass")
            )
            .font(
              .system(size: 20)
            ).padding(20).frame(maxWidth: .infinity, alignment: .leading)
          }
          if model.section == .bilibili, let plugin = model.activePlugin,
            plugin.manifest.authentication != nil
          {
            TVButton(
              selected: model.focus.row == model.moduleToolbarRow && model.focus.column == 1,
              action: { model.showLogin(plugin) }, hover: { model.focus.select(row: model.moduleToolbarRow, column: 1) }
            ) {
              Label(model.login.accountTitle(for: plugin), systemImage: "person.crop.circle")
                .font(.system(size: 18, weight: .medium)).padding(20)
            }
          }
          if model.section == .library, !model.libraryPath.isEmpty {
            TVButton(
              selected: model.focus.row == 1 && model.focus.column == 1,
              action: { model.backLibraryCollection() },
              hover: { model.focus.select(row: 1, column: 1) }
            ) {
              Label(L("返回上层"), systemImage: "arrow.uturn.backward").font(
                .system(size: 18, weight: .medium)
              ).padding(20)
            }
            TVButton(
              selected: model.focus.row == 1 && model.focus.column == 2,
              action: {
                if let series = model.libraryPath.first { model.metadata.present(series) }
              },
              hover: { model.focus.select(row: 1, column: 2) }
            ) {
              Label(L("匹配信息"), systemImage: "wand.and.stars").font(.system(size: 18, weight: .medium))
                .padding(20)
            }
          }
          if model.section == .bilibili, model.moduleSupportsLookup {
            TVButton(selected: model.focus.row == model.moduleToolbarRow && model.focus.column == model.moduleLookupColumn,
              action: { model.showModuleLookup() }, hover: { model.focus.select(row: model.moduleToolbarRow, column: model.moduleLookupColumn) }) {
              Label(L("打开视频编号"), systemImage: "link").font(.system(size: 18, weight: .medium)).padding(20)
            }
          }
          if model.section == .library && model.needsSMBReconnect {
            TVButton(selected: model.focus.row == 1 && model.focus.column == model.smbReconnectColumn,
              action: { model.reconnectSMB() }, hover: { model.focus.select(row: 1, column: model.smbReconnectColumn) }) {
              Label(L("连接 NAS"), systemImage: "externaldrive.connected.to.line.below")
                .font(.system(size: 18, weight: .medium)).padding(20)
            }
          }
          if model.section == .library && model.libraryPath.isEmpty {
            TVButton(selected: model.focus.row == 1 && model.focus.column == model.savedSourcesColumn,
              action: { model.presentSavedSources() }, hover: { model.focus.select(row: 1, column: model.savedSourcesColumn) }) {
              Label(L("内容来源"), systemImage: "rectangle.stack").font(.system(size: 18, weight: .medium)).padding(20)
            }
            TVButton(selected: model.focus.row == 1 && model.focus.column == model.overviewColumn,
              action: { model.presentLibraryOverview() }, hover: { model.focus.select(row: 1, column: model.overviewColumn) }) {
              Label(L("全部资料库"), systemImage: "square.grid.2x2").font(.system(size: 18, weight: .medium)).padding(20)
            }
            TVButton(selected: model.focus.row == 1 && model.focus.column == model.libraryBrowseColumn,
              action: { model.presentLibraryBrowse() }, hover: { model.focus.select(row: 1, column: model.libraryBrowseColumn) }) {
              Label(L("筛选排序"), systemImage: "line.3.horizontal.decrease").font(.system(size: 18, weight: .medium)).padding(20)
            }
          }
        }
      }
      if model.section == .bilibili {
        if !model.modulePath.isEmpty {
          Text(model.moduleLocationTitle).font(.system(size: 16, weight: .medium)).lineLimit(2)
        }
      }
      if model.section == .library, !model.libraryPath.isEmpty {
        Text(([L("影片库")] + model.libraryPath.map(\.title)).joined(separator: "  ›  "))
          .font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary).lineLimit(2)
      }
    }.id(model.section == .settings || model.section == .extensions || model.hasBilibiliTabs ? "heading" : "row-\(model.moduleToolbarRow)")
  }
  func mediaGrid(width: CGFloat) -> some View {
    let cardWidth = max(
      130, (width - 128 - CGFloat(model.gridColumns - 1) * 24) / CGFloat(model.gridColumns))
    let landscape =
      model.section == .bilibili || (model.section == .library && !model.libraryPath.isEmpty)
    return LazyVStack(alignment: .leading, spacing: 24) {
      HStack {
        Text(LT(
          model.section == .bilibili
            ? (model.search.isEmpty ? (model.hasBilibiliTabs && model.modulePath.isEmpty ? model.bilibiliChannel.title : "内容") : "搜索结果")
            : (!model.search.isEmpty
              ? "搜索结果"
              : (model.libraryPath.last?.kind == .series
                ? L("Episodes") : (model.libraryPath.last?.kind == .season ? L("Episodes") : (model.section == .home ? "来自影片库" : (model.libraryBrowseOptions.kind == .all ? "全部影片" : model.libraryBrowseOptions.kind.title)))))
        ))
        .font(.system(size: 25, weight: .bold)).tracking(-0.5)
        Spacer()
        if model.section == .library && model.libraryPath.isEmpty {
          Text(L("\(model.filtered.count) 项") + " · " + model.libraryBrowseOptions.kind.title + " · " + model.libraryBrowseOptions.order.title).font(.system(size: 15)).foregroundStyle(.secondary)
        }
      }
      if model.filtered.isEmpty, !model.loading, model.section != .bilibili || model.moduleLoadFailure == nil {
        ContentUnavailableView(
          model.moduleNeedsLogin && model.section == .bilibili
            ? L("登录\(model.moduleTitle)") : LT(model.section == .library && model.libraryPath.isEmpty && !model.libraryCatalog.root.isEmpty ? "当前分类没有匹配内容" : (model.search.isEmpty ? "还没有内容" : "没有匹配的影片")),
          systemImage: model.moduleNeedsLogin && model.section == .bilibili ? "qrcode" : "film")
          .frame(maxWidth: .infinity, minHeight: 300)
      }
      LazyVStack(alignment: .leading, spacing: 30) {
      ForEach(Array(model.mediaRows.enumerated()), id: \.offset) { row, items in
        HStack(alignment: .top, spacing: 24) {
          ForEach(Array(items.enumerated()), id: \.element.id) { col, item in
            let singleEpisode = model.libraryCatalog.singlePlayableEpisode(of: item)
            let videoItem = singleEpisode ?? item
            TVButton(
              selected: model.focus.row == row + model.mediaFocusOffset
                && model.focus.column == col,
              subtleFocus: true,
              action: { model.activateCard(item) },
              hover: {
                model.focus.select(row: row + model.mediaFocusOffset, column: col)
              }
            ) {
              VStack(alignment: .leading, spacing: 0) {
                ZStack {
                  if (item.isFolder || (item.isLibraryCollection && singleEpisode == nil)) && item.poster == nil {
                    LinearGradient(
                      colors: [.cyan.opacity(0.3), .blue.opacity(0.08)], startPoint: .topLeading,
                      endPoint: .bottomTrailing)
                    Image(systemName: item.isFolder ? "folder.fill" : "tv").font(
                      .system(size: 42, weight: .light)
                    )
                    .foregroundStyle(.cyan.opacity(0.85))
                  } else {
                    Artwork(address: singleEpisode?.poster ?? item.poster, placeholder: item.kind == .photo ? "photo" : item.kind == .audio ? "music.note" : "film",
                      videoURL: videoItem.source == "local" && videoItem.localMetadata?.sourceReachable != false ? videoItem.url.flatMap(URL.init(string:)) : nil)
                  }
                }.frame(
                  height: model.activePlugin?.manifest.nativeLibraries?.contains("music") == true && model.section == .bilibili ? cardWidth : (landscape ? max(100, cardWidth * 9 / 16) : max(200, cardWidth * 1.5))
                ).clipShape(RoundedRectangle(cornerRadius: 16))
                  .overlay(alignment: .bottomLeading) {
                    if item.localMetadata?.sourceReachable == false {
                      Label(L("片源离线"), systemImage: "externaldrive.badge.exclamationmark")
                        .font(.system(size: 11, weight: .semibold)).padding(8)
                        .background(.ultraThinMaterial, in: Capsule()).padding(9)
                    }
                  }
                  .overlay(alignment: .topTrailing) {
                    if item.isLibraryCollection && singleEpisode == nil {
                      Text(item.kind == .series ? "剧集" : item.kind == .versions ? "多版本" : item.kind == .extras ? "附加内容" : "季").font(
                        .system(size: 12, weight: .semibold)
                      )
                      .padding(.horizontal, 10).padding(.vertical, 6).background(
                        .ultraThinMaterial, in: Capsule()
                      ).padding(9)
                    }
                  }
                  .overlay(alignment: .topLeading) {
                    if item.localMetadata?.metadataReadFailed == true {
                      Text(L("资料待更新")).font(.system(size: 11, weight: .medium)).padding(8)
                        .background(.black.opacity(0.8), in: Capsule()).padding(8)
                    }
                  }
                VStack(alignment: .leading, spacing: 7) {
                  Text(item.title).font(.system(size: 16, weight: .semibold))
                    .lineLimit(2, reservesSpace: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .anchorPreference(key: MediaTitleAnchorKey.self, value: .bounds) { anchor in
                      model.focus.row == row + model.mediaFocusOffset && model.focus.column == col ? [item.id: anchor] : [:]
                    }
                  Text(item.subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineLimit(1)
                }.padding(.horizontal, 3).padding(.top, 13).padding(.bottom, 7)
              }.frame(width: cardWidth)
            }
          }
          Spacer(minLength: 0)
        }.id("row-\(row + model.mediaFocusOffset)")
      }
      }
      if model.section == .bilibili, model.moduleHasFooter {
        if let failure = model.moduleLoadFailure {
          VStack(alignment: .leading, spacing: 12) {
            Label(model.online.isEmpty ? "暂时无法加载" : "更多内容未能加载", systemImage: "wifi.exclamationmark")
              .font(.system(size: 25, weight: .semibold))
            Text(failure.message).font(.system(size: 17)).foregroundStyle(.secondary).lineLimit(4)
          }.padding(.vertical, 20)
        }
        if model.moduleLoadFailure != nil { TVButton(
          selected: model.focus.row == model.mediaFocusOffset + model.mediaRows.count,
          action: {
            model.focus.select(row: model.mediaFocusOffset + model.mediaRows.count, column: 0)
            model.activate()
          }, hover: { model.focus.select(row: model.mediaFocusOffset + model.mediaRows.count, column: 0) }
        ) {
          Label(L("重试加载"), systemImage: "arrow.clockwise").font(.system(size: 19, weight: .medium)).padding(
            22
          ).frame(maxWidth: .infinity)
        }.id("row-\(model.mediaFocusOffset + model.mediaRows.count)")
        } else {
          HStack(spacing: 12) { ProgressView(); Text(L("正在加载更多视频…")).foregroundStyle(.secondary) }
            .padding(28).frame(maxWidth: .infinity)
            .onScrollVisibilityChange(threshold: 0.1) { visible in if visible { model.loadMoreModuleIfNeeded() } }
            .id("next-" + (model.moduleNextPage ?? ""))
        }
      }
    }
  }
  var extensions: some View {
    VStack(alignment: .leading, spacing: 25) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(alignment: .top, spacing: 22) {
          ForEach(Array(model.plugins.enumerated()), id: \.element.id) { index, plugin in
            pluginCard(plugin, column: index)
          }
          appCard(
            model.plugins.count, title: "管理插件",
            symbol: "puzzlepiece.extension", colors: [.indigo, .purple]
          ) {
            model.focus.select(row: 1, column: model.plugins.count)
            model.activate()
          }
        }
      }
    }.id("row-1")
  }
  var settings: some View { TVSettings(model: model) }
  @ViewBuilder var libraryIndexStatus: some View {
    if !model.libraryStatus.isEmpty {
      Text(model.libraryStatus).font(.system(size: 16)).foregroundStyle(.secondary)
    }
    if let date = model.libraryIndexedAt {
      Text(L("上次完整扫描：") + date.formatted(date: .abbreviated, time: .shortened))
        .font(.system(size: 14)).foregroundStyle(.secondary)
    }
    if let error = model.libraryIndexError {
      Text(L("索引未保存或无法恢复：") + error).font(.system(size: 15)).foregroundStyle(.orange)
    }
  }
  func noticeOverlay(_ text: String) -> some View {
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 30) {
        Label(L("提示"), systemImage: "info.circle").font(.title2.bold()).foregroundStyle(accent)
        Text(text).font(.system(size: 22)).lineSpacing(10).fixedSize(
          horizontal: false, vertical: true)
        Button(L("知道了")) { model.notice = nil }.buttonStyle(.borderedProminent).controlSize(
          .large)
      }.padding(44).frame(maxWidth: 800).tvPopupSurface(radius: 30)
    }
  }
}

struct DetailView: View {
  @ObservedObject var model: AppModel
  let item: MediaItem
  var body: some View {
    ZStack(alignment: .bottomLeading) {
      ink.ignoresSafeArea()
      Artwork(primaryAddresses: backdrops, fallbackAddress: item.poster, fallbackBlur: 18).ignoresSafeArea()
      LinearGradient(
        colors: [.black.opacity(0.1), ink.opacity(0.35), ink], startPoint: .top, endPoint: .bottom
      ).ignoresSafeArea()
      LinearGradient(
        colors: [.black.opacity(0.65), .clear], startPoint: .leading, endPoint: .trailing
      ).ignoresSafeArea()
      VStack(alignment: .leading, spacing: 22) {
        Spacer()
        Text(model.sourceTitle(for: item)).font(.system(size: 16, weight: .semibold))
          .foregroundStyle(.white.opacity(0.7))
        Text(item.title).font(.system(size: 56, weight: .bold)).tracking(-1.8)
          .lineLimit(3).minimumScaleFactor(0.7).allowsTightening(true).frame(
          maxWidth: 820, alignment: .leading)
        Text(item.subtitle).font(.system(size: 17, weight: .medium)).foregroundStyle(
          .white.opacity(0.6))
        if let record = model.resumeRecord(for: item), record.resumablePosition > 0 {
          VStack(alignment: .leading, spacing: 10) {
            Text(L("上次看到 \(resumeClock(record.position))")).font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
            if let length = record.duration {
              ProgressView(value: min(record.position, length), total: length).tint(.white).frame(width: 320)
            }
          }
        }
        HStack(spacing: 20) {
          ForEach(Array(model.detailControls(for: item).enumerated()), id: \.element) { index, control in
            detailButton(control, index: index)
          }
        }.padding(.vertical, 10)
        Text(item.overview).font(.system(size: 19)).foregroundStyle(.white.opacity(0.75))
          .lineSpacing(7).lineLimit(4).frame(maxWidth: 760, alignment: .leading)
        if item.localMetadata?.metadataReadFailed == true {
          Label(L("部分资料未能读取。修复来源资料后，可在设置中重新识别。"), systemImage: "exclamationmark.circle")
            .font(.system(size: 16)).foregroundStyle(.orange)
        }
        if let address = item.metadataAttribution, let url = URL(string: address) {
          Link(L("信息来源：\(url.host?.contains("tvmaze") == true ? "TVmaze" : "TMDB")"), destination: url)
            .font(.system(size: 14)).foregroundStyle(.secondary)
        }
        Text(
          L("\(item.source == "local" ? L("本地媒体") : L("应用内容"))   ·   \(model.preferredEngine.title)   ·   菜单键选择引擎")
        )
        .font(.system(size: 13)).foregroundStyle(.secondary)
      }.padding(.horizontal, 70).padding(.bottom, 65)
    }
  }
  func resumeClock(_ value: Double) -> String {
    guard value.isFinite, value >= 0, value < Double(Int.max) else { return "--:--" }
    let seconds = Int(value)
    return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
      : String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }
  @ViewBuilder func detailButton(_ control: AppModel.DetailControl, index: Int) -> some View {
    if control == .play {
      Button { model.performDetailControl(control, item: item) } label: {
            Label(model.loading ? L("正在解析…") : ((model.resumeRecord(for: item)?.resumablePosition ?? 0) > 0 ? L("继续播放") : L("播放影片")), systemImage: "play.fill")
              .font(.system(size: 19, weight: .semibold)).foregroundStyle(.black)
              .padding(.horizontal, 45).padding(.vertical, 20).background(.white, in: Capsule())
          }.buttonStyle(.plain).focusable(false).shadow(
            color: .white.opacity(model.detailAction == index ? 0.25 : 0), radius: 20
          )
          .tvPointerFocus { model.detailAction = index }
    } else if control == .close {
      Button { model.performDetailControl(control, item: item) } label: {
            Image(systemName: "xmark").font(.system(size: 18, weight: .semibold)).frame(
              width: 60, height: 60
            ).background(.ultraThinMaterial, in: Circle())
          }.buttonStyle(.plain).focusable(false).accessibilityLabel(L("返回"))
            .overlay(
              Circle().strokeBorder(
                .white.opacity(model.detailAction == index ? 1 : 0),
                lineWidth: 2)
            )
            .tvPointerFocus { model.detailAction = index }
    } else {
      TVButton(selected: model.detailAction == index, action: { model.performDetailControl(control, item: item) },
        hover: { model.detailAction = index }) {
        switch control {
        case .restart: Label(L("从头播放"), systemImage: "arrow.counterclockwise").font(.system(size: 19)).padding(20)
        case .metadata: Label(item.localMetadata?.episode == nil ? L("匹配信息") : L("匹配系列信息"), systemImage: "wand.and.stars").font(.system(size: 19)).padding(20)
        case .collection: Label(L("选集"), systemImage: "list.bullet.rectangle").font(.system(size: 19)).padding(20)
        case .watchlist: Label(model.watchlist.contains(item) ? L("已加入待看") : L("加入待看"), systemImage: model.watchlist.contains(item) ? "checkmark" : "plus").font(.system(size: 19)).padding(20)
        default: EmptyView()
        }
      }
    }
  }
  var backdrops: [String] {
    guard let address = item.poster, let url = URL(string: address) else { return [] }
    return url.isFileURL
      ? LocalArtworkCandidates.backdrops(in: url.deletingLastPathComponent()).map(\.absoluteString)
      : [address]
  }
}

struct KeyboardScreen: View {
  @ObservedObject var model: AppModel
  var body: some View {
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 8) {
        HStack {
          Text(model.keyboardTitle).font(.system(size: 28, weight: .bold))
          Spacer()
          Text(
            model.keyboardSymbols
              ? L("符号")
              : (model.keyboardSecret
                ? L("密码输入")
                : (model.chinese ? L("中文 · 拼音") : "English · \(model.uppercase ? "ABC" : "abc")"))
          )
          .foregroundStyle(accent)
          Button(L("关闭")) { model.handle(.back) }.buttonStyle(.plain).focusable(false).padding(.leading, 20)
          Button(L("粘贴")) { model.pasteKeyboardText() }.buttonStyle(.plain).focusable(false).padding(.leading, 12)
        }
        HStack {
          Image(systemName: model.keyboardSecret ? "lock" : "magnifyingglass").foregroundStyle(
            .secondary)
          if model.keyboardSecret {
            Text(model.inputText.isEmpty ? L("请输入") : model.keyboardDisplayText)
              .lineLimit(1).truncationMode(.head)
              .foregroundStyle(model.inputText.isEmpty ? .secondary : .primary)
          } else {
            SystemTextInput(model: model).id(model.keyboardSession)
              .frame(maxWidth: .infinity).frame(height: 38)
              .overlay(alignment: .leading) {
                if model.inputText.isEmpty && model.composing.isEmpty {
                  Text(L("请输入")).foregroundStyle(.secondary).allowsHitTesting(false)
                }
              }
          }
          Spacer()
        }.font(.system(size: 25)).padding(20).background(
          Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16))
        ScrollViewReader { shelf in
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
              if !model.composing.isEmpty {
                Text(L("拼音 · ") + model.composing).font(.system(size: 17, weight: .medium))
                  .foregroundStyle(accent).padding(.trailing, 12)
              }
              ForEach(Array(model.candidateActions.enumerated()), id: \.offset) {
                index, candidate in
                TVButton(
                  selected: model.candidateFocus && model.candidateIndex == index,
                  action: {
                    model.candidateIndex = index
                    model.commitCandidate()
                  },
                  hover: {
                    model.candidateFocus = true
                    model.candidateIndex = index
                  }
                ) {
                  Text(index < model.candidates.count ? candidate : LT(candidate)).font(.system(size: 19)).lineLimit(1).fixedSize(
                    horizontal: true, vertical: false
                  ).padding(12)
                }.id(index)
              }
              if model.candidates.isEmpty {
                Text(LT(
                  !model.chinese || model.keyboardSymbols
                    ? "直接输入后，选择“完成”提交"
                    : (!model.pinyin.ready && model.chinese
                      ? (model.pinyin.failure == nil ? "正在准备中文词库…" : "中文暂不可用，请切换英文")
                      : (model.composing.isEmpty ? "输入拼音后，按 ↑ 选择候选词" : "暂无候选，可继续输入或切换英文"))
                )).foregroundStyle(
                  .secondary)
              }
              Spacer(minLength: 0)
            }.padding(.horizontal, 4).padding(.vertical, 4)
          }.frame(height: 56)
            .onChange(of: model.candidateIndex) { _, index in
              withAnimation(.easeInOut(duration: 0.15)) { shelf.scrollTo(index, anchor: .center) }
            }
        }
        ForEach(Array(model.keyboardRows.enumerated()), id: \.offset) { row, keys in
          HStack(spacing: 10) {
            Spacer(minLength: 0)
            ForEach(Array(keys.enumerated()), id: \.offset) { col, key in
              TVButton(
                selected: !model.candidateFocus && model.keyboardFocus.row == row
                  && model.keyboardFocus.column == col,
                action: { model.pressKey(key) },
                hover: {
                  model.candidateFocus = false
                  model.keyboardFocus.select(row: row, column: col)
                }
              ) {
                Text(LT(
                  key == "符号" && model.keyboardSymbols
                    ? "字母"
                    : (key.count == 1 && key.rangeOfCharacter(from: .letters) != nil
                      && !model.uppercase
                      ? key.lowercased() : key)
                ))
                .font(
                  .system(size: row == model.keyboardRows.count - 1 ? 20 : 23, weight: .medium)
                )
                .frame(width: row == model.keyboardRows.count - 1 ? min(115, (878 - CGFloat(keys.count - 1) * 10) / CGFloat(keys.count)) : 70, height: 40)
              }
            }
            Spacer(minLength: 0)
          }
        }
      }.padding(24).frame(width: 950).tvPopupSurface(radius: 30)
    }
  }
}

struct NativePlayer: NSViewRepresentable {
  let player: AVPlayer
  let range: VideoRangeChoice
  var onReady: ((AVPlayer) -> Void)? = nil
  final class Coordinator { var observation: NSKeyValueObservation? }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeNSView(context: Context) -> AVPlayerView {
    let view = AVPlayerView()
    view.player = player
    view.controlsStyle = .none
    view.videoGravity = .resizeAspect
    context.coordinator.observation = view.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak player] view, _ in
      guard let player, view.isReadyForDisplay, view.player === player else { return }
      Task { @MainActor in onReady?(player) }
    }
    if #available(macOS 26.0, *) { view.preferredDisplayDynamicRange = range.avDisplayRange }
    return view
  }
  func updateNSView(_ view: AVPlayerView, context: Context) {
    if view.player !== player { view.player = player }
    if #available(macOS 26.0, *), view.preferredDisplayDynamicRange != range.avDisplayRange {
      view.preferredDisplayDynamicRange = range.avDisplayRange
    }
  }
}

struct PlayerScreen: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject var model: AppModel
  var nativeOverlay = false
  let symbols = [
    "gobackward.10", "pause.fill", "goforward.10", "waveform", "captions.bubble", "xmark", "slider.horizontal.3", "forward.end.fill", "speedometer", "speaker.wave.2", "backward.end.fill", "tv",
  ]
  let labels = ["后退", "播放/暂停", "前进", "音轨", "字幕", "退出播放", "画面", "下一个", "倍速", "音量", "上一个", "清晰度"].map { LT($0) }
  var body: some View {
    ZStack(alignment: .bottom) {
      if nativeOverlay { Color.clear.ignoresSafeArea() } else { Color.black.ignoresSafeArea() }
      if let player = model.player {
        NativePlayer(player: player, range: model.videoPresentation.preference,
          onReady: { [weak model] player in model?.benchmarkDisplayReady(player) })
          .id(ObjectIdentifier(player)).ignoresSafeArea()
      }
      if let engine = model.vlcEngine { VLCVideoSurface(engine: engine).ignoresSafeArea() }
      VStack(alignment: .leading, spacing: 8) {
        Text(model.playbackTitle).font(.system(size: 22, weight: .semibold)).lineLimit(1)
        if let item = model.playingItem {
          let active = model.playerControlsVisible && model.playbackInterruption == nil
          if item.source == "mtv.bilibili", !item.subtitle.isEmpty {
            HStack(spacing: 7) {
              Text(item.subtitle).font(.system(size: 14, weight: .medium)).lineLimit(1).frame(maxWidth: 220, alignment: .leading)
              if !item.overview.isEmpty {
                Text("·").foregroundStyle(.secondary)
                PlaybackMarquee(text: item.overview, active: active)
              }
            }
          } else {
            let summary = [item.subtitle, item.overview].filter { !$0.isEmpty }.joined(separator: " · ")
            if !summary.isEmpty { PlaybackMarquee(text: summary, active: active) }
          }
        }
        if let message = model.mpvEngine?.subtitleError { Text(message).font(.system(size: 15)).foregroundStyle(.secondary) }
        VStack(spacing: 6) {
          PlayerTimeline(model: model).id(model.playingItem?.id)
          HStack(spacing: 8) {
            ForEach(model.playerControlIndices, id: \.self) { index in
              control(index, primary: index < 3)
            }
          }
        }.padding(.horizontal, 14).padding(.vertical, 10)
          .tvGlass(radius: 22)

      }.padding(.horizontal, 28).padding(.bottom, 18).padding(.top, 28).background(
        LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
      )
      .opacity(model.playerControlsVisible && model.playbackInterruption == nil && !model.playbackCompleted ? 1 : 0)
      .allowsHitTesting(model.playerControlsVisible && model.playbackInterruption == nil && !model.playbackCompleted)
      .animation(
        reduceMotion ? nil : .easeInOut(duration: 0.25), value: model.playerControlsVisible)
      if let message = model.playbackInterruption {
        TVPopupBackdrop()
        VStack(spacing: 24) {
          Image(systemName: "play.slash").font(.system(size: 38, weight: .light))
          Text(model.playbackInterruptionTitle).font(.system(size: 32, weight: .semibold))
          Text(message).font(.system(size: 20)).foregroundStyle(.secondary)
            .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
          HStack(spacing: 20) {
            ForEach(0..<2) { index in
              TVButton(selected: model.playbackInterruptionButton == index,
                action: { model.playbackInterruptionCommand(index) },
                hover: { model.playbackInterruptionButton = index }) {
                Text(index == 0 ? L("重新播放") : L("返回")).font(.system(size: 20, weight: .semibold))
                  .frame(width: 180, height: 64)
              }
            }
          }
        }.padding(44).frame(width: 620).tvPopupSurface(radius: 30)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }.onContinuousHover { phase in
      if case .active = phase, TVPointerFocus.acceptsHover { model.showPlayerControls() }
    }
  }
  private func control(_ index: Int, primary: Bool) -> some View {
    let enabled = index == 7 ? model.canStepVideo(1) : index == 10 ? model.canStepVideo(-1) : true
    return TVButton(selected: !model.playerTimelineFocused && model.playerButton == index, action: { model.cancelPlayerScrub(); model.playerButton = index; model.playerCommand(index) }, hover: {
      model.cancelPlayerScrub(); model.playerButton = index; model.showPlayerControls()
    }) {
      VStack(spacing: 4) {
        Image(systemName: index == 1 && model.paused ? "play.fill" : symbols[index])
          .font(.system(size: primary ? 27 : 20, weight: .medium))
        Text(index == 8 ? String(format: "%g×", model.playbackRate) : index == 11 ? model.bilibiliActualQualityTitle : labels[index])
          .font(.system(size: 12, weight: .medium)).lineLimit(1)
      }.frame(maxWidth: .infinity, minHeight: 54)
    }.disabled(!enabled).opacity(enabled ? 1 : 0.38)
  }
  func clock(_ value: Double) -> String {
    guard value.isFinite else { return "--:--" }
    return String(format: "%02d:%02d", Int(max(0, value)) / 60, Int(max(0, value)) % 60)
  }
}

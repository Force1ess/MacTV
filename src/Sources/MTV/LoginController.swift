import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import MTVCore
import OSLog
import Security
import SwiftUI

@MainActor final class LoginController: ObservableObject {
  @Published var plugin: PluginRecord?
  @Published var state = "idle"
  @Published var message = ""
  @Published var qrImage: NSImage?
  @Published var selectedButton = 1
  @Published private(set) var savedSessions: Set<String> = []
  @Published private(set) var accountErrors: [String: String] = [:]
  @Published private(set) var chromeImportDiagnostic: [String: Any] = [:]
  private var chromeImportAllowsInteraction = false
  private var chromeAuthorizationProfile: LocalChromeQuark.Profile?
  private var chromeReadOperation: ChromeStorageReadOperation?
  var controlRejection: String?
  var onDismiss: ((PluginRecord, Bool) -> Void)?
  var onMediaSessionRevoked: (() -> Void)?
  private var task: Task<Void, Never>?
  private var generation = UUID()
  private var challenge: PluginLoginResponse?
  private var reloadOnClose = false
  private var isFixture = false
  private var refreshVersions: [String: UUID] = [:]
  private var waitingForPrivacyReturn = false
  private var privacyObserver: NSObjectProtocol?
  private var chromeProfiles: [LocalChromeQuark.Profile] = []
  @Published private(set) var chromeProfilesUnavailable = false
  private var chromeAccessIsTemporary = false
  init() {
    privacyObserver = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in
        guard let self, self.waitingForPrivacyReturn, self.state == "chromeProfiles", self.plugin != nil else { return }
        self.waitingForPrivacyReturn = false
        self.beginLocalChromeImport()
      }
    }
  }
  var isPresented: Bool { plugin != nil }
  var platformVerificationIsReal: Bool { state == "authorized" && !isFixture }
  var chromeImportInProgress: Bool {
    state == "loading" && ["profile-discovery", "cookie-read", "platform-verification"].contains(chromeImportDiagnostic["stage"] as? String ?? "")
  }
  var availableChromeProfileTitles: [String] { chromeProfiles.map(\.title) }
  func selectChromeProfile(named title: String, allowInteraction: Bool = false) -> Bool {
    let matching = chromeProfiles.filter { $0.title == title }
    guard state == "chromeProfiles", !chromeProfilesUnavailable, matching.count == 1 else { return false }
    chromeImportAllowsInteraction = allowInteraction
    importLocalChromeProfile(matching[0])
    return true
  }
  var supportsChromeImport: Bool { ["mtv.quark", "mtv.bilibili"].contains(plugin?.id ?? "") }
  var authorizationHost: String? {
    guard let address = challenge?.qrURL, let url = URL(string: address) else { return nil }
    return url.host
  }
  var buttons: [String] {
    if state == "chromeAuthorization" { return ["授权并导入", "扫码登录", "关闭"] }
    if state == "chromeProfiles" { return chromeProfiles.map(\.title) + ["打开访问授权", "重新检测", "在Chrome登录", "通过Chrome扩展导入", "扫码登录", "关闭"] }
    if state == "authorized" || state == "stored" {
      let revoke = !isFixture && plugin?.id == "mtv.quark" && FirstPartyMediaScope.quarkHosts.contains { MediaSessionApprovalStore().permits(pluginID: "mtv.quark", host: $0) }
      return ["完成", "重新登录", "退出登录"] + (supportsChromeImport ? ["从Chrome导入"] : []) + (revoke ? ["撤销播放会话授权"] : [])
    }
    var titles = ["刷新二维码", "关闭"]
    if supportsChromeImport { titles.append("从Chrome导入") }
    if let plugin, savedSessions.contains(plugin.id) || accountErrors[plugin.id] != nil {
      titles.append("退出登录")
    }
    return titles
  }
  func displayedButtonTitle(_ title: String, at index: Int) -> String {
    if state == "chromeProfiles", index < chromeProfiles.count { return title }
    return LT(title)
  }
  var displayedButtonTitles: [String] { buttons.enumerated().map { displayedButtonTitle($0.element, at: $0.offset) } }
  var displayedMessage: String { LT(message) }
  func accountTitle(for plugin: PluginRecord) -> String {
    if accountErrors[plugin.id] != nil { return L("登录异常") }
    return savedSessions.contains(plugin.id) ? L("管理登录") : L("扫码登录")
  }
  func refresh(_ plugin: PluginRecord) {
    guard plugin.manifest.authentication != nil else { return }
    let version = UUID()
    refreshVersions[plugin.id] = version
    Task {
      do {
        let exists = try await Task.detached {
          guard let session = try PluginSessionStore().load(pluginID: plugin.id) else {
            return false
          }
          try session.validate(for: plugin.manifest)
          return true
        }.value
        guard refreshVersions[plugin.id] == version else { return }
        if exists { savedSessions.insert(plugin.id) } else { savedSessions.remove(plugin.id) }
        accountErrors.removeValue(forKey: plugin.id)
      } catch {
        if refreshVersions[plugin.id] == version {
          accountErrors[plugin.id] = error.localizedDescription
        }
      }
    }
  }
  func present(_ plugin: PluginRecord) {
    close(reload: false)
    self.plugin = plugin
    if let error = accountErrors[plugin.id] {
      state = "failed"
      message = error
      selectedButton = 1
    } else if savedSessions.contains(plugin.id) {
      state = "stored"
      message = "已保存登录。你可以直接使用，或重新登录其他账号。"
      selectedButton = 0
    } else {
      generate()
    }
  }
  func generate() {
    guard let plugin else { return }
    task?.cancel()
    generation = UUID()
    let current = generation
    state = "loading"
    message = "正在生成登录二维码…"
    qrImage = nil
    challenge = nil
    selectedButton = 1
    task = Task {
      do {
        let result = try await PluginClient.executeWithSession(
          plugin, action: "login", input: ["step": "start"])
        guard !Task.isCancelled, generation == current else { return }
        let response = try JSONDecoder().decode(PluginLoginResponse.self, from: result.data)
        try response.validateChallenge(for: plugin.manifest)
        guard let image = Self.renderQR(response.qrURL ?? "") else {
          throw MTVError.message("无法生成二维码图像")
        }
        challenge = response
        qrImage = image
        state = "waiting"
        message = response.message ?? "等待扫码"
        while !Task.isCancelled, generation == current {
          try await Task.sleep(for: .seconds(3))
          guard !Task.isCancelled, generation == current else { return }
          if Date().timeIntervalSince1970 >= (response.expiresAt ?? 0) {
            state = "expired"
            message = "二维码已过期，请重新生成"
            qrImage = nil
            return
          }
          let result = try await PluginClient.executeWithSession(
            plugin, action: "login", input: ["step": "poll", "token": response.token ?? ""])
          guard !Task.isCancelled, generation == current else { return }
          let update = try JSONDecoder().decode(PluginLoginResponse.self, from: result.data)
          switch update.state {
          case "waiting", "scanned":
            state = update.state
            message = update.message ?? "等待确认"
          case "expired":
            state = "expired"
            message = "二维码已过期，请重新生成"
            qrImage = nil
            return
          case "authorized":
            guard let session = result.session else {
              throw MTVError.message("平台没有返回完整的模块会话，未保存登录状态")
            }
            try session.validate(for: plugin.manifest)
            let verified = plugin.id == "mtv.quark" ? try await QuarkImportedSessionValidator.verify(session) : session
            try verified.validate(for: plugin.manifest)
            guard !Task.isCancelled, generation == current else { return }
            try await Task.detached { try PluginSessionStore().save(verified) }.value
            guard !Task.isCancelled, generation == current else { return }
            savedSessions.insert(plugin.id)
            refreshVersions[plugin.id] = UUID()
            accountErrors.removeValue(forKey: plugin.id)
            state = "authorized"
            message = "登录完成，登录状态已保存在这台 Mac。"
            qrImage = nil
            challenge = nil
            selectedButton = 0
            reloadOnClose = true
            return
          default: throw MTVError.message("插件返回了未知的登录状态")
          }
        }
      } catch {
        guard !Task.isCancelled, generation == current else { return }
        state = "failed"
        message = error.localizedDescription
        qrImage = nil
        challenge = nil
      }
    }
  }
  func close(reload: Bool = true) {
    chromeReadOperation?.cancel(); chromeReadOperation = nil
    task?.cancel()
    task = nil
    generation = UUID()
    let previous = plugin
    let shouldReload = reloadOnClose
    let wasFixture = isFixture
    plugin = nil
    challenge = nil
    qrImage = nil
    message = ""
    state = "idle"
    reloadOnClose = false
    isFixture = false
    waitingForPrivacyReturn = false
    chromeImportDiagnostic = [:]
    chromeAuthorizationProfile = nil
    if reload && !wasFixture, let previous { onDismiss?(previous, shouldReload) }
  }
  func move(_ amount: Int) {
    selectedButton = min(max(0, selectedButton + amount), buttons.count - 1)
  }
  var selectedActionRequiresChromeImport: Bool {
    if state == "chromeProfiles", chromeProfiles.indices.contains(selectedButton) { return true }
    let title = buttons[min(selectedButton, buttons.count - 1)]
    return ["从Chrome导入", "授权并导入", "打开访问授权", "重新检测", "通过Chrome扩展导入"].contains(title)
  }
  var selectedActionRequiresInteractiveUI: Bool {
    let title = buttons[min(selectedButton, buttons.count - 1)]
    return ["授权并导入", "打开访问授权", "通过Chrome扩展导入", "在Chrome登录"].contains(title)
  }
  func activate() {
    activate(allowChromeImport: true, allowInteraction: true)
  }
  func activate(allowChromeImport: Bool, allowInteraction: Bool) {
    controlRejection = nil
    guard allowChromeImport || !selectedActionRequiresChromeImport else {
      controlRejection = "account-import-not-enabled"
      message = "本机控制入口没有开启Chrome导入。"; return
    }
    guard allowInteraction || !selectedActionRequiresInteractiveUI else {
      controlRejection = "requires-interactive-action"
      message = "此操作需要在应用界面中完成。"; return
    }
    guard !selectedActionRequiresChromeImport || !chromeImportInProgress else {
      controlRejection = "account-import-busy"; return
    }
    let title = buttons[min(selectedButton, buttons.count - 1)]
    if state == "chromeProfiles" {
      if chromeProfiles.indices.contains(selectedButton) { chromeImportAllowsInteraction = false; importLocalChromeProfile(chromeProfiles[selectedButton]) }
      else if title == "扫码登录" { generate() }
      else if title == "在Chrome登录" { openChromeLogin() }
      else if title == "打开访问授权" { waitingForPrivacyReturn = true; ChromeFolderAccess.openPrivacySettings() }
      else if title == "重新检测" { beginLocalChromeImport(allowInteraction: false) }
      else if title == "通过Chrome扩展导入" { beginChromeImport() } else { close() }
      return
    }
    if title == "授权并导入", state == "chromeAuthorization", let profile = chromeAuthorizationProfile {
      chromeImportAllowsInteraction = true; importLocalChromeProfile(profile)
    }
    else if title == "扫码登录" { generate() }
    else if title == "从Chrome导入" { beginLocalChromeImport(allowInteraction: false) }
    else if title == "撤销播放会话授权", plugin?.id == "mtv.quark", !isFixture {
      MediaSessionApprovalStore().revokeAll(pluginID: "mtv.quark")
      onMediaSessionRevoked?()
      message = "已撤销播放连接授权，下次播放时将重新询问。"; selectedButton = 0
    }
    else if title == "完成" || title == "关闭" {
      close()
    } else if title == "退出登录" {
      signOut()
    } else {
      generate()
    }
  }
  func beginLocalChromeImport(allowInteraction: Bool = false) {
    guard supportsChromeImport else { return }
    guard !chromeImportInProgress else { controlRejection = "account-import-busy"; return }
    chromeReadOperation?.cancel(); chromeReadOperation = nil
    task?.cancel(); generation = UUID(); let current = generation
    qrImage = nil; challenge = nil; state = "loading"
    chromeProfiles = []; chromeProfilesUnavailable = false
    chromeImportDiagnostic = ["stage": "profile-discovery"]
    chromeImportAllowsInteraction = allowInteraction
    chromeAuthorizationProfile = nil
    message = "正在查找这台Mac的Chrome资料…"
    task = Task {
      do {
        let discovered = try await ChromeProfileDiscovery.load()
        let profiles = discovered.profiles
        if let warning = discovered.savedAccessWarning {
          Logger(subsystem: "local.mtv.preview", category: "chrome-import").notice(
            "Saved directory access unavailable; current Chrome directory read succeeded. domain=\(warning.domain, privacy: .public) code=\(warning.code)")
        }
        guard generation == current, !Task.isCancelled else { return }
        guard !profiles.isEmpty else { throw MTVError.message("这台Mac没有Chrome资料。请先打开Chrome登录对应平台，或使用扫码登录。") }
        chromeProfiles = profiles; state = "chromeProfiles"; selectedButton = 0
        if profiles.count == 1, !isFixture { importLocalChromeProfile(profiles[0]); return }
        message = (chromeAccessIsTemporary ? L("本次已允许访问，重开应用可能需重新选择。\n") : "") + L("选择已经登录\(plugin?.title ?? L("此平台"))的Chrome资料。直接导入可能需要单独解锁Chrome钥匙；也可选择扩展导入。")
      } catch {
        guard generation == current, !Task.isCancelled else { return }
        chromeProfilesUnavailable = true; chromeProfiles = []
        state = "chromeProfiles"; selectedButton = 0
        let failure = error as NSError
        let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError
        recordChromeFailure(error, stage: "profile-discovery")
        Logger(subsystem: "local.mtv.preview", category: "chrome-import").error(
          "Profile discovery failed domain=\(failure.domain, privacy: .public) code=\(failure.code) underlyingDomain=\(underlying?.domain ?? "none", privacy: .public) underlyingCode=\(underlying?.code ?? 0)")
        message = ChromeProfileDiscovery.message(for: error)
      }
    }
  }
  func openChromeLogin() {
    guard supportsChromeImport, let url = URL(string: plugin?.id == "mtv.quark" ? "https://pan.quark.cn/" : "https://www.bilibili.com/"),
      let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome") else { return }
    NSWorkspace.shared.open([url], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
    message = "在这台Mac的Chrome完成登录后，返回这里选择对应资料导入。"
  }
  func back() {
    if ["chromeProfiles", "chromeAuthorization"].contains(state), let plugin {
      if isFixture { state = "waiting"; message = "离线二维码布局测试"; qrImage = Self.renderQR("https://example.invalid/mtv-login-ui-fixture") }
      else { present(plugin) }
    } else { close() }
  }
  private func importLocalChromeProfile(_ profile: LocalChromeQuark.Profile) {
    guard let plugin, supportsChromeImport else { return }
    task?.cancel(); generation = UUID(); let current = generation
    state = "loading"; message = "正在读取所选平台登录。如系统要求授权，请处理提示；取消后可使用扩展或扫码登录。"
    let allowInteraction = chromeImportAllowsInteraction
    chromeAuthorizationProfile = profile
    chromeReadOperation?.cancel()
    let operation = ChromeStorageReadOperation(); chromeReadOperation = operation
    chromeImportDiagnostic = ["stage": "cookie-read", "interactive": allowInteraction, "reader": "stable-native-helper-v1"]
    task = Task {
      // The helper has its own deadline. Keep a UI deadline as well, cancel its
      // owned process and invalidate this attempt so late data cannot be saved.
      let readDeadline: Task<Void, Never>? = allowInteraction ? nil : Task { @MainActor [weak self] in
        do { try await Task.sleep(for: .seconds(20)) } catch { return }
        guard let self, self.generation == current,
          self.chromeImportDiagnostic["stage"] as? String == "cookie-read" else { return }
        operation.cancel(); self.task?.cancel(); self.generation = UUID()
        self.chromeImportDiagnostic = ["stage": "cookie-read", "interactive": false, "timedOut": true]
        self.state = "failed"
        self.message = "读取 Chrome 登录超时。请回到这台 Mac 的 MacTV 检查系统授权，再重试；也可以使用扫码登录。"
        self.selectedButton = 1
      }
      defer { readDeadline?.cancel(); if chromeReadOperation === operation { chromeReadOperation = nil } }
      var stage = "cookie-read"
      do {
        let imported = try await Task.detached { try LocalChromeQuark.read(profile, provider: plugin.id, allowInteraction: allowInteraction, operation: operation) }.value
        guard !Task.isCancelled, generation == current else { return }
        stage = "platform-verification"; chromeImportDiagnostic = ["stage": stage]
        let verified = try await ChromePlatformSession.verify(imported)
        try verified.validate(for: plugin.manifest)
        guard !Task.isCancelled, generation == current else { return }
        try await Task.detached { try PluginSessionStore().save(verified) }.value
        guard !Task.isCancelled, generation == current else { return }
        savedSessions.insert(plugin.id); refreshVersions[plugin.id] = UUID(); accountErrors.removeValue(forKey: plugin.id)
        chromeImportDiagnostic = ["stage": "completed", "platformVerified": true, "interactive": allowInteraction, "reader": "stable-native-helper-v1"]
        state = "authorized"; message = "Chrome登录已通过平台验证，并保存在这台Mac。"; selectedButton = 0; reloadOnClose = true
      } catch {
        guard !Task.isCancelled, generation == current else { return }
        recordChromeFailure(error, stage: stage)
        if stage == "cookie-read", (error as NSError).domain == NSOSStatusErrorDomain,
          [Int(errSecInteractionNotAllowed), Int(errSecAuthFailed)].contains((error as NSError).code) {
          state = "chromeAuthorization"
          message = "需要先允许 MacTV 读取 Chrome 登录。选择“授权并导入”后才会打开系统提示，也可以扫码登录。"
          selectedButton = 0
        } else {
          state = "failed"
          message = error is CancellationError ? "登录读取已取消或等待超时。请重试，或扫码登录。" : error.localizedDescription
          selectedButton = 1
        }
      }
    }
  }
  private func recordChromeFailure(_ error: Error, stage: String) {
    let failure = error as NSError, underlying = (error as NSError).userInfo[NSUnderlyingErrorKey] as? NSError
    let values = [failure, underlying].compactMap { $0 }
    let permission = values.contains {
      ($0.domain == NSCocoaErrorDomain && [257, 513].contains($0.code)) ||
      ($0.domain == NSPOSIXErrorDomain && [1, 13].contains($0.code)) ||
      ($0.domain == NSOSStatusErrorDomain && [Int(errSecInteractionNotAllowed), Int(errSecAuthFailed)].contains($0.code))
    }
    chromeImportDiagnostic = ["stage": stage, "domain": failure.domain, "code": failure.code,
      "requiresSystemAuthorization": permission]
    if let underlying { chromeImportDiagnostic["underlyingDomain"] = underlying.domain; chromeImportDiagnostic["underlyingCode"] = underlying.code }
  }
  func beginChromeImport() {
    guard let plugin, supportsChromeImport else { return }
    task?.cancel(); generation = UUID(); let current = generation
    qrImage = nil; challenge = nil; state = "importing"
    task = Task {
      do {
        try ChromeFolderAccess.restoreIfAvailable()
        let folder = try ChromeQuarkImport.installConnector()
        let previous = try? PluginSessionStore().load(pluginID: plugin.id)?.savedAt
        NSWorkspace.shared.activateFileViewerSelecting([folder])
        if let chrome = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.google.Chrome"), let extensions = URL(string: "chrome://extensions/") {
          _ = try await NSWorkspace.shared.open([extensions], withApplicationAt: chrome, configuration: NSWorkspace.OpenConfiguration())
        }
        message = "首次使用：在Chrome扩展程序页打开开发者模式，加载已显示的ChromeQuarkBridge文件夹。在扩展中选择对应平台，再点击导入。无需读取Chrome解密钥匙；登录保存在本机文件中。"
        for _ in 0..<180 {
          try await Task.sleep(for: .seconds(1))
          guard generation == current, !Task.isCancelled else { return }
          UserDefaults.standard.synchronize()
          let stored = try await Task.detached { try PluginSessionStore().load(pluginID: plugin.id) }.value
          if let stored, stored.savedAt != previous {
            savedSessions.insert(plugin.id); refreshVersions[plugin.id] = UUID(); accountErrors.removeValue(forKey: plugin.id)
            state = "authorized"; message = "Chrome登录已通过平台验证，并保存在这台Mac。"; selectedButton = 0; reloadOnClose = true
            return
          }
        }
        state = "failed"; message = "等待Chrome导入超时。可重新导入，或使用扫码登录。"
      } catch {
        guard generation == current, !Task.isCancelled else { return }
        state = "chromeProfiles"; selectedButton = chromeProfiles.count
        message = "Chrome连接组件尚未完成注册。请先允许访问Chrome资料文件夹，再重试扩展导入；也可以使用扫码登录。"
      }
    }
  }
  func signOut() {
    guard let plugin else { return }
    task?.cancel()
    generation = UUID()
    let current = generation
    task = Task {
      do {
        try await Task.detached { try PluginSessionStore().remove(pluginID: plugin.id) }.value
        guard generation == current else { return }
        if plugin.id == "mtv.quark", !isFixture {
          MediaSessionApprovalStore().revokeAll(pluginID: plugin.id)
          onMediaSessionRevoked?()
        }
        savedSessions.remove(plugin.id)
        refreshVersions[plugin.id] = UUID()
        accountErrors.removeValue(forKey: plugin.id)
        qrImage = nil
        challenge = nil
        state = "signedOut"
        message = "此模块已退出登录，其他模块和客户端不受影响。"
        selectedButton = 1
        reloadOnClose = true
      } catch {
        guard generation == current else { return }
        state = "failed"
        message = error.localizedDescription
      }
    }
  }
  static func renderQR(_ text: String) -> NSImage? {
    guard !text.isEmpty, text.utf8.count <= 4096 else { return nil }
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let raw = filter.outputImage else { return nil }
    let paper = CIImage(color: .white).cropped(to: raw.extent.insetBy(dx: -4, dy: -4))
    let output = raw.composited(over: paper).transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    guard let image = CIContext().createCGImage(output, from: output.extent)
    else { return nil }
    return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
  }
  /// The UI test uses a nonfunctional URL, never screenshots a real login token.
  func presentFixture(_ plugin: PluginRecord) {
    guard CommandLine.arguments.contains("--ui-smoke") else { return }
    close(reload: false)
    isFixture = true
    self.plugin = plugin
    state = "waiting"
    message = "离线二维码布局测试，不会登录任何账号。"
    qrImage = Self.renderQR("https://example.invalid/mtv-login-ui-fixture")
    selectedButton = 1
  }
}

struct LoginPanel: View {
  @ObservedObject var controller: LoginController
  private var status: String {
    switch controller.state {
    case "chromeAuthorization": return L("允许导入登录")
    case "chromeProfiles": return L("从Chrome导入")
    case "stored", "authorized": return L("登录已保存")
    case "loading": return L("正在准备")
    case "failed": return L("需要重试")
    case "importing": return L("等待Chrome导入")
    default: return L("扫码登录")
    }
  }
  var body: some View {
    TVDialog(title: L("登录\(controller.plugin?.title ?? L("应用"))"), symbol: "person.crop.circle", brand: controller.plugin?.id) {
      HStack(alignment: .top, spacing: 36) {
        VStack(spacing: 16) {
          ZStack {
            if controller.state == "chromeProfiles" || controller.state == "importing" || controller.state == "chromeAuthorization" {
              RoundedRectangle(cornerRadius: 24).fill(.primary.opacity(0.05))
              Image(systemName: "globe").font(.system(size: 70, weight: .ultraLight)).foregroundStyle(.secondary)
            } else {
              RoundedRectangle(cornerRadius: 24).fill(.white)
              if let image = controller.qrImage {
                Image(nsImage: image).interpolation(.none).resizable().scaledToFit().padding(20)
              } else if controller.state == "loading" { ProgressView().tint(.black).scaleEffect(1.5) }
              else {
                Image(systemName: controller.state == "authorized" || controller.state == "stored" ? "checkmark.shield" : "qrcode")
                  .font(.system(size: 74, weight: .light)).foregroundStyle(.black.opacity(0.65))
              }
            }
          }.frame(width: 240, height: 240)
          Text(status).font(.system(size: 18, weight: .medium))
          if let host = controller.authorizationHost { Text(host).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1) }
        }.frame(width: 250)
        VStack(alignment: .leading, spacing: 20) {
          if !["stored", "authorized"].contains(controller.state), !controller.displayedMessage.isEmpty {
            Text(controller.displayedMessage).font(.system(size: 18)).lineSpacing(4)
              .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
          }
          ScrollViewReader { scroll in
            ScrollView {
              VStack(spacing: 8) {
                ForEach(Array(controller.buttons.enumerated()), id: \.offset) { index, title in
                  TVButton(selected: controller.selectedButton == index,
                    action: { controller.selectedButton = index; controller.activate() },
                    hover: { controller.selectedButton = index }) {
                    HStack {
                      Text(controller.displayedButtonTitle(title, at: index)).font(.system(size: 20, weight: .medium)); Spacer()
                      Image(systemName: title == "完成" ? "checkmark" : (title == "关闭" ? "xmark" : "chevron.right"))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                    }.padding(.horizontal, 18).frame(height: 52)
                  }.id(index)
                }
              }.padding(12)
            }.scrollIndicators(.hidden)
              .onChange(of: controller.selectedButton) { _, index in scroll.scrollTo(index, anchor: .center) }
          }.frame(maxHeight: .infinity)
        }.frame(maxWidth: .infinity)
      }.frame(height: 360)
    }
  }
}

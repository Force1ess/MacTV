import Foundation
import MTVCore

@MainActor final class PluginManagerController: ObservableObject {
  enum Control { case back, add, sources, addSource, openSource(PluginSource), toggleSource(PluginSource), removeSource(PluginSource), sourceReference, refreshSource, bundledCatalog, installEntry(PluginSourceEntry), open(InstalledPluginPackage), cancel, approve, toggle(InstalledPluginPackage), remove(InstalledPluginPackage), confirmRemove(InstalledPluginPackage), reload, reviewRecovery, confirmRecovery, info(String) }
  @Published private(set) var isPresented = false
  @Published private(set) var loading = false
  @Published private(set) var packages: [InstalledPluginPackage] = []
  @Published private(set) var review: PluginInstallReview?
  @Published private(set) var detail: InstalledPluginPackage?
  @Published private(set) var confirmingRemoval = false
  @Published private(set) var registryFailed = false
  @Published private(set) var recoveryReview: PluginRegistryRecoveryReview?
  @Published private(set) var lastRegistryBackup: URL?
  @Published private(set) var message = ""
  @Published var selection = 0
  @Published private(set) var sourceMode=false
  @Published private(set) var sources: [PluginSource]=[]
  @Published private(set) var selectedSource: PluginSource?
  @Published private(set) var catalog: PluginSourceCatalog?
  @Published private(set) var catalogIsBundled=false
  @Published private(set) var catalogRevision: String?=nil
  @Published private(set) var reviewOrigin: String?
  let store = PluginClient.packages
  var onAdd: (() -> Void)?
  var onAddSource: (() -> Void)?
  var onSourceReference: (() -> Void)?
  let sourceStore=PluginSourceServices.store
  var onChanged: (() async -> Void)?
  var onWillChange: ((String) -> Void)?
  var onRegistryWillChange: (() -> Void)?
  private var generation = UUID()
  private var operation: Task<Void, Never>?
  private var mutation: Task<Void, Never>?
  private var cleanup: Task<Void, Never>?
  private var cleanupActive = false
  private var cleanupID = UUID()
  var hasPendingMutation: Bool { mutation != nil || cleanupActive }
  func controlID(_ control: Control) -> String {
    switch control {
    case .back: return "back"
    case .sources: return "sources"
    case .addSource: return "source.add"
    case .openSource(let source): return "source.open:"+source.id
    case .toggleSource: return "source.toggle"
    case .removeSource: return "source.remove"
    case .sourceReference: return "source.reference"
    case .refreshSource: return "source.refresh"
    case .bundledCatalog: return "source.bundled"
    case .installEntry(let entry): return "source.install:"+entry.id
    case .approve: return "approve"
    case .cancel: return "cancel"
    case .add: return "install.folder"
    case .open(let package): return "installed:"+package.id
    case .toggle: return "plugin.toggle"
    case .remove: return "plugin.remove"
    case .confirmRemove: return "plugin.remove.confirm"
    case .reload: return "reload"
    case .reviewRecovery: return "recovery.review"
    case .confirmRecovery: return "recovery.confirm"
    case .info: return "info"
    }
  }
  var diagnostics: [String:Any] {
    ["packages":packages.map { ["id":$0.id,"title":$0.manifest.displayName,"source":sourceTitle(for:$0)] },
      "presented":isPresented,"loading":loading,"sourceMode":sourceMode,"sourceID":selectedSource?.id ?? "",
      "catalogRevision":catalogRevision ?? "", "catalogOrigin":catalog == nil ? "none":(catalogIsBundled ? "bundled":"git"),
      "catalogEntries":catalog?.plugins.map { ["id":$0.id,"name":LocalControlJSON.safeText($0.name),"version":$0.version] } ?? [],
      "reviewPlugin":review?.manifest.id ?? "","message":LocalControlJSON.safeText(message),"selection":selection,
      "controls":controls.enumerated().map { ["index":$0.offset,"id":controlID($0.element)] as [String:Any] }]
  }
  var controls: [Control] {
    if loading { return [.back] }
    if recoveryReview != nil { return [.cancel, .confirmRecovery] }
    if registryFailed { return [.back, .reload, .reviewRecovery] }
    if let review { return [.cancel, .approve, .info(reviewOrigin ?? ("来源目录：" + review.source.path))] + permissions(review.manifest).map(Control.info)
      + (review.noticeNames.isEmpty ? [] : [.info("随包保留文档：" + review.noticeNames.joined(separator: "、"))]) }
    if sourceMode {
      if let source=selectedSource {
        return [.back] + (source.enabled ? [.refreshSource] + (PluginSourceServices.bundledCatalog(for:source)==nil ? []:[.bundledCatalog]) + (catalog?.plugins.map { $0.isCompatible ? Control.installEntry($0):Control.info($0.displayName+" · "+L("Requires a newer MacTV")) } ?? []) : [])
          + [.toggleSource(source),.sourceReference,.removeSource(source)]
      }
      return [.back,.addSource]+sources.map(Control.openSource)
    }
    if let detail {
      if confirmingRemoval { return [.cancel, .confirmRemove(detail)] }
      return [.back, .toggle(detail), .remove(detail)] + [.info(L("Source: \(sourceTitle(for: detail))"))] + permissions(detail.manifest).map(Control.info)
    }
    return [.back, .sources, .add] + packages.map(Control.open)
  }
  func sourceTitle(for package: InstalledPluginPackage) -> String {
    guard let origin = package.origin else { return L("Local installation") }
    return sources.first { $0.id == origin.sourceID && $0.repository == origin.repository }.map { LT($0.name) }
      ?? origin.repository
  }
  var title: String {
    if recoveryReview != nil { return L("重建插件安装清单？") }
    if review != nil { return L("安装前确认") }
    if confirmingRemoval { return L("移除这个插件？") }
    if sourceMode { return selectedSource?.name ?? L("Plugin Sources") }
    return detail?.manifest.displayName ?? L("应用管理")
  }
  var summary: String {
    if let recoveryReview { return L("原清单无法读取（\(recoveryReview.byteCount) 字节）。确认后先保留原件，再清空外部模块的安装登记。\n模块文件与 MacTV 登录状态保留；内置模块和媒体不受影响。外部模块需重新选择目录并确认安装。") }
    if registryFailed { return L("安装清单未能读取，未自动覆盖。可先重新读取，或审阅备份与重建范围。") }
    if let review { return L("\(review.manifest.displayName) · \(review.manifest.version)\n请只安装来源可信的应用，并核对下方访问权限。") + (review.replacingVersion.map { L("\n将替换已安装版本 \($0)，并启用新版本。") } ?? "") }
    if confirmingRemoval { return L("移除这个应用，并清除它在 MacTV 中的登录。你的影片与云端文件会保留。") }
    if sourceMode, let source = selectedSource {
      return source.repository + " · " + source.reference
    }
    return ""
  }
  private func permissions(_ manifest: PluginManifest) -> [String] {
    let names = ["browse": "浏览内容", "search": "搜索", "resolve": "播放视频", "folders": "浏览文件夹", "login": "平台登录", "history": "加入继续观看", "lookup": "用视频编号打开", "watchlist": "加入待看片单", "continuation": "播放后续内容", "launch": "打开已安装的应用", "library": "读取本机媒体资料库"]
    var values = [L("功能：") + manifest.capabilities.map { LT(names[$0] ?? $0) }.joined(separator: L("、"))]
    if let launch = manifest.applicationLaunch { values.append(L("打开应用：") + launch.bundleID + " · " + launch.url) }
    if let titles=manifest.applicationLaunch?.windowTitles { values.append(L("Observe application windows: \(titles.joined(separator:", "))")) }
    let libraries = ["photos":"图片：本地目录与已连接的云盘", "pictures": "图片：已添加的媒体来源", "music": "音乐：这台 Mac 的音乐资料库",
      "quark-pictures": "图片：已登录的夸克网盘"]
    values += (manifest.nativeLibraries ?? []).map { LT(libraries[$0] ?? $0) }
    values += manifest.domains.map { L("联网域名：") + $0 }
    values += (manifest.playbackDomains ?? []).map { L("媒体播放域名（含子域）：") + $0 }
    values += (manifest.artworkDomains ?? []).map { L("封面域名（含子域）：") + $0 }
    values += (manifest.postEndpoints ?? []).map { L("允许 POST：https://") + $0.host + $0.path }
    if let auth = manifest.authentication {
      values += auth.issuerDomains.map { L("登录签发域名：") + $0 }
      values += auth.sessionDomains.map { L("模块会话发送域名：") + $0 }
      values += auth.qrDomains.map { L("扫码链接域名：") + $0 }
      if let exchange = auth.ticketExchange { values.append(L("登录票据兑换：") + exchange.endpoint) }
    }
    if manifest.domains.isEmpty { values.append(L("没有声明联网域名")) }
    values.append(L("宿主不提供文件写入、系统命令或其它模块登录状态的接口。"))
    return values
  }
  func present() {
    close(); isPresented = true; reload()
  }
  func reload() {
    operation?.cancel(); let attempt = UUID(); generation = attempt
    loading = true; message = ""; selection = 0; registryFailed = false; recoveryReview = nil; packages = []
    detail = nil; confirmingRemoval = false
    let cleanupToWait = cleanup, mutationToWait = mutation
    operation = Task {
      defer { if generation == attempt { operation = nil } }
      do {
        await cleanupToWait?.value
        await mutationToWait?.value
        let values = try await store.installed()
        guard generation == attempt, isPresented else { return }
        packages = values
        do {
          let knownSources = try await sourceStore.sources()
          guard generation == attempt, isPresented else { return }
          sources = knownSources
        } catch { if generation == attempt, isPresented { message = error.localizedDescription } }
        if generation == attempt { loading = false }
      } catch { if generation == attempt, isPresented { message = error.localizedDescription; registryFailed = true; loading = false } }
    }
  }
  private func reviewRegistryRecovery() {
    operation?.cancel(); let attempt = UUID(); generation = attempt
    loading = true; message = ""; selection = 0
    operation = Task {
      defer { if generation == attempt { operation = nil } }
      do {
        let value = try await store.reviewRegistryRecovery()
        guard generation == attempt, isPresented else { return }
        recoveryReview = value; loading = false
      } catch { if generation == attempt, isPresented { message = error.localizedDescription; loading = false } }
    }
  }
  private func confirmRegistryRecovery() {
    guard let recoveryReview, mutation == nil else { return }
    let attempt = generation
    loading = true; selection = 0; message = ""
    mutation = Task {
      do {
        let directory = await store.root
        let destination = directory.appendingPathComponent("RegistryRecovery")
        let backup = try await Task.detached(priority: .userInitiated) { try recoveryReview.writeBackup(in: destination) }.value
        lastRegistryBackup = backup.url
        try await store.commitRegistryRecovery(backup)
        PluginClient.cancelExternal(); onRegistryWillChange?()
        await onChanged?()
        if generation == attempt, isPresented {
          self.recoveryReview = nil; registryFailed = false; packages = try await store.installed()
          message = L("安装清单已重建。原件：") + backup.url.path; loading = false; selection = 0
        }
      } catch {
        if generation == attempt, isPresented {
          self.recoveryReview = nil; registryFailed = true; message = error.localizedDescription; loading = false; selection = 0
        }
      }
      mutation = nil
    }
  }
  func prepare(_ directory: URL) {
    operation?.cancel(); let attempt = UUID(); generation = attempt
    loading = true; message = ""; selection = 0; detail = nil; confirmingRemoval = false
    operation = Task {
      defer { if generation == attempt { operation = nil } }
      do {
        let value = try await store.prepare(directory: directory)
        guard generation == attempt, isPresented else { await store.cancel(value.id); return }
        review = value; loading = false
      } catch { if generation == attempt, isPresented { message = error.localizedDescription; loading = false } }
    }
  }
  func move(_ delta: Int) { selection = min(max(0, selection + delta), controls.count - 1) }
  func activate() {
    guard controls.indices.contains(selection) else { return }
    switch controls[selection] {
    case .back: back()
    case .add: onAdd?()
    case .sources: sourceMode=true; reloadSources()
    case .addSource: onAddSource?()
    case .openSource(let source): selectedSource=source; catalog=nil; catalogRevision=nil; catalogIsBundled=false; message=""; selection=1
    case .toggleSource(let source): mutateSource { try await self.sourceStore.setEnabled(source.id,!source.enabled) }
    case .removeSource(let source): mutateSource { try await self.sourceStore.remove(source.id); self.selectedSource=nil }
    case .sourceReference: onSourceReference?()
    case .refreshSource: refreshSource()
    case .bundledCatalog:
      guard let source=selectedSource else { return }
      catalog=PluginSourceServices.bundledCatalog(for:source); catalogRevision=nil; catalogIsBundled=true; message=""; selection=0
    case .installEntry(let entry): prepareEntry(entry)
    case .open(let package): detail = package; confirmingRemoval = false; selection = 0; message = ""
    case .cancel:
      if recoveryReview != nil { recoveryReview = nil; selection = 0; return }
      if let review { Task { await store.cancel(review.id) }; self.review = nil; reviewOrigin=nil }
      confirmingRemoval = false; selection = 0
    case .approve:
      guard let review else { return }; let id = review.manifest.id
      change(id: id) { _ = try await self.store.approve(review.id); self.review = nil; self.reviewOrigin=nil }
    case .toggle(let package): change(id: package.id) { try await self.store.setEnabled(package.id, !package.enabled); self.detail = nil }
    case .remove: confirmingRemoval = true; selection = 0
    case .confirmRemove(let package):
      change(id: package.id) {
        if package.manifest.authentication != nil { try PluginSessionStore().remove(pluginID: package.id) }
        try await self.store.remove(package.id); self.detail = nil; self.confirmingRemoval = false
      }
    case .reload: reload()
    case .reviewRecovery: reviewRegistryRecovery()
    case .confirmRecovery: confirmRegistryRecovery()
    case .info: break
    }
  }
  func reloadSources() {
    operation?.cancel(); let attempt=UUID(); generation=attempt; loading=true; message=""; selection=0
    operation=Task {
      defer { if generation==attempt { loading=false; operation=nil } }
      do {
        _ = try PluginSourceServices.configuration.get()
        let list=try await sourceStore.sources()
        guard generation==attempt, isPresented else { return }
        sources=list
        if let id=selectedSource?.id { selectedSource=list.first(where:{$0.id==id}); catalog=nil; catalogRevision=nil; catalogIsBundled=false }
      } catch { if generation==attempt, isPresented { message=error.localizedDescription } }
    }
  }
  func addSource(_ value: String) {
    let url=value.trimmingCharacters(in:.whitespacesAndNewlines)
    mutateSource { _ = try await self.sourceStore.add(url) }
  }
  func saveSourceReference(_ value: String) {
    guard let source=selectedSource else { return }
    mutateSource { try await self.sourceStore.setReference(source.id,value) }
  }
  private func mutateSource(_ action: @escaping @MainActor () async throws -> Void) {
    guard mutation==nil else { return }
    let attempt=generation; loading=true; message=""
    mutation=Task {
      do {
        _ = try PluginSourceServices.configuration.get()
        try await action()
        if generation==attempt, isPresented {
          sources=try await sourceStore.sources()
          if let id=selectedSource?.id { selectedSource=sources.first(where:{$0.id==id}) }
          catalog=nil; catalogRevision=nil; catalogIsBundled=false; selection=0
        }
      } catch { if generation==attempt, isPresented { message=error.localizedDescription } }
      if generation==attempt { loading=false }; mutation=nil
    }
  }
  func refreshSource() {
    guard let source=selectedSource, source.enabled else { return }
    operation?.cancel(); let attempt=UUID(); generation=attempt; loading=true; message=""; catalog=nil; catalogRevision=nil; catalogIsBundled=false; selection=0
    operation=Task {
      defer { if generation==attempt { loading=false; operation=nil } }
      do {
        guard generation==attempt, isPresented else { return }
        let result=try await PluginSourceServices.client.catalog(source:source)
        guard generation==attempt, isPresented, selectedSource?.id==source.id else { return }
        catalogRevision=result.revision; catalog=result.catalog
      } catch { if generation==attempt, isPresented { message=error.localizedDescription } }
    }
  }
  private func prepareEntry(_ entry: PluginSourceEntry) {
    guard entry.isCompatible else { message=L("Requires a newer MacTV"); return }
    guard let source=selectedSource else { return }
    let bundled=catalogIsBundled, revision=catalogRevision
    operation?.cancel(); let attempt=UUID(); generation=attempt; loading=true; message=""; selection=0
    operation=Task {
      defer { if generation==attempt { loading=false; operation=nil } }
      do {
        let value=try await PluginSourceServices.prepare(entry,source:source,bundled:bundled,revision:revision)
        guard generation==attempt, isPresented else { await store.cancel(value.id); return }
        review=value; reviewOrigin=L("Source: \(source.name)")+(bundled ? " · "+L("Bundled catalog"):"")
      } catch { if generation==attempt, isPresented { message=error.localizedDescription } }
    }
  }
  private func change(id: String, action: @escaping @MainActor () async throws -> Void) {
    onWillChange?(id)
    loading = true; selection = 0; message = ""
    let attempt = generation
    mutation = Task {
      do {
        try await action()
        PluginClient.cancel(pluginID: id)
        await PhotoResources.release(owner:id)
        await onChanged?()
        if generation == attempt, isPresented {
          packages = try await store.installed(); loading = false; selection = 0
        }
      } catch { if generation == attempt, isPresented { message = error.localizedDescription; loading = false } }
      mutation = nil
    }
  }
  func back() {
    if sourceMode, review==nil {
      operation?.cancel(); operation=nil; generation=UUID(); loading=false; message=""; selection=0
      if selectedSource != nil { selectedSource=nil; catalog=nil; catalogRevision=nil; catalogIsBundled=false }
      else { sourceMode=false; reload() }
      return
    }
    if loading { close(); return }
    if review != nil || confirmingRemoval || recoveryReview != nil { selection = 0; activate(); return }
    if detail != nil { detail = nil; selection = 0; return }
    close()
  }
  func close() {
    let reader = operation, previous = cleanup, reviewID = review?.id
    isPresented = false; generation = UUID(); reader?.cancel(); operation = nil; loading = false
    if reader != nil || previous != nil || reviewID != nil {
      let attempt = UUID(); cleanupID = attempt; cleanupActive = true
      cleanup = Task {
        await previous?.value; await reader?.value
        if let reviewID { await store.cancel(reviewID) }
        if cleanupID == attempt { cleanupActive = false; cleanup = nil }
      }
    }
    review = nil; detail = nil; confirmingRemoval = false; recoveryReview = nil; reviewOrigin=nil
    sourceMode=false; selectedSource=nil; catalog=nil; catalogRevision=nil; catalogIsBundled=false; catalogRevision=nil
  }
  func waitForPendingChanges() async { await mutation?.value; await cleanup?.value }
}

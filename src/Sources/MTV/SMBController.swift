import Darwin
import Foundation
import MTVCore
import OSLog

enum SMBControl: Equatable {
  case address, mode, username, password, connect, connectRoot, useDirectory, parent, close
  case rememberPassword, networkRecovery, saveProfile, savedConnections, newConnection,
    deleteProfile, confirmDelete,
    cancelDelete
  case profile(UUID)
  case folder(URL)
  case retryDirectory, browseRoot, failureDetails, reconnect
}

@MainActor final class SMBController: ObservableObject {
  private let logger = Logger(subsystem: "local.mtv.preview", category: "smb")
  @Published var isPresented = false
  @Published var address = ""
  @Published var username = ""
  @Published var password = ""
  @Published var guest = false
  @Published var rememberPassword = false
  @Published var reconnectOnNetworkReturn = false
  var onConnectionFailure: ((Bool) -> Void)?
  var onProfileSaved: ((SMBProfile) -> Void)?
  private var automaticExpected: SMBProfile?
  @Published private(set) var profiles: [SMBProfile] = []
  @Published private(set) var activeProfileID: UUID?
  @Published private(set) var profilesLoading = false
  var profileStore: SMBProfileStore
  var credentialStore: SMBCredentialStore
  var connectionObserverForTesting: ((SMBLocation, String, String, Bool) -> Void)?
  var directoryReaderForTesting: ((URL, URL) async throws -> (directory: URL, folders: [URL]))?
  var directoryDeadlineForTesting: Double?
  var directorySelectionResolverForTesting: (@Sendable (URL, URL) throws -> SMBDirectorySelection)?
  var onDirectorySelectionForTesting: ((SMBDirectorySelection) -> Void)?
  private var operation: Task<Void, Never>?
  private var saveTask: Task<Void, Never>?
  private var formTouched = false
  @Published private(set) var phase = "form"
  @Published private(set) var message = ""
  @Published private(set) var directory: URL?
  @Published private(set) var folders: [URL] = []
  @Published private(set) var failure: SMBFailure?
  @Published private(set) var directoryReadPending = false
  private var directoryReadID: UUID?
  private var attemptedDirectory: URL?
  @Published var selection = 0
  var onEdit: ((SMBControl) -> Void)?
  var onSelect: ((MountedSMBShare, URL, SMBProfile?) -> Void)?
  var onDismiss: (() -> Void)?
  var onFailureDetails: ((String) -> Void)?
  private let client = SMBMountClient()
  private var share: MountedSMBShare?
  private var connectedProfile: SMBProfile?
  private var generation = UUID()
  private var browseTimeout: Task<Void, Never>?
  init() {
    if CommandLine.arguments.contains("--ui-smoke") {
      let scope = "\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)"
      profileStore = SMBProfileStore(
        file: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
          "Library/Application Support/MTV/TestResults/smb-profiles-\(scope).json"))
      credentialStore = SMBCredentialStore(service: "local.mtv.preview.smb-test." + scope)
    } else {
      profileStore = SMBProfileStore()
      credentialStore = SMBCredentialStore()
    }
  }
  var storedPasswordAvailable: Bool {
    guard rememberPassword, let id = activeProfileID,
      let old = profiles.first(where: { $0.id == id }),
      old.rememberPassword, let draft = try? draftProfile()
    else { return false }
    return draft.sameAccount(as: old)
  }
  var readOnlyConnected: Bool { share?.readOnly == true && phase == "browse" && directory != nil }
  var controls: [SMBControl] {
    if phase == "connecting" || phase == "loading" || phase == "saving" { return [.close] }
    if phase == "profiles" { return profiles.map { .profile($0.id) } + [.newConnection, .close] }
    if phase == "confirmDelete" { return [.confirmDelete, .cancelDelete] }
    if phase == "browseError" {
      if failure?.stage == .mountValidation { return [.failureDetails] + (directoryReadPending ? [] : [.reconnect]) + [.close] }
      return (failure == nil ? [] : [.failureDetails]) + (!directoryReadPending && share != nil && attemptedDirectory != nil ? [.retryDirectory, .browseRoot] : []) + [.close]
    }
    if phase == "browse" {
      guard directory != nil else { return [.close] }
      return [.useDirectory] + (directory?.path == share?.mount.path ? [] : [.parent])
        + folders.map(SMBControl.folder) + [.close]
    }
    return (failure == nil ? [] : [.failureDetails]) + [.address, .mode] + (guest ? [] : [.username, .password, .rememberPassword])
      + [.networkRecovery]
      + [.saveProfile, .connect]
      + (((try? SMBLocation(address).subdirectory.isEmpty) == false) ? [.connectRoot] : [])
      + (profiles.isEmpty ? [] : [.savedConnections])
      + (activeProfileID == nil ? [] : [.deleteProfile]) + [.close]
  }
  var directoryLabel: String {
    guard let share, let directory = phase == "browseError" ? attemptedDirectory : directory else { return "" }
    let relative = String(directory.path.dropFirst(share.mount.path.count))
    return relative.isEmpty ? L("共享根目录") : relative
  }
  func present(profileID: UUID? = nil, automatic: SMBProfile? = nil) {
    close(notify: false)
    automaticExpected = automatic
    directory = nil
    folders = []
    isPresented = true
    phase = "form"
    message = ""
    selection = 0
    formTouched = false
    profiles = []
    activeProfileID = nil
    rememberPassword = false
    reconnectOnNetworkReturn = false
    profilesLoading = true
    let attempt = generation
    let store = profileStore
    operation = Task {
      await saveTask?.value
      do {
        let values = try await store.load()
        guard generation == attempt, isPresented else { return }
        profiles = values
        profilesLoading = false
        if automatic != nil && !values.contains(where: { $0.id == profileID }) {
          throw MTVError.message("自动重连的连接已删除，请手动选择")
        }
        if let profileID, values.contains(where: { $0.id == profileID }), !formTouched {
          selectProfile(profileID)
          if let automatic {
            guard let current = values.first(where: { $0.id == profileID }),
              current.sameAccount(as: automatic), current.address == automatic.address,
              current.allowsAutomaticReconnect
            else { throw MTVError.message("自动重连设置或认证目标已改变，请手动确认") }
            connect()
          }
        } else if !formTouched && phase == "form" && !values.isEmpty {
          phase = "profiles"
          selection = 0
        }
      } catch {
        guard generation == attempt, isPresented else { return }
        profilesLoading = false
        message = L("已保存连接无法读取：\(error.localizedDescription)")
        failed()
      }
    }
  }
  func move(_ step: Int) { selection = min(max(0, selection + step), max(0, controls.count - 1)) }
  func activate() {
    guard controls.indices.contains(selection) else { return }
    formTouched = true
    switch controls[selection] {
    case .address, .username, .password: onEdit?(controls[selection])
    case .mode:
      guest.toggle()
      if guest { password = "" }
      if guest { rememberPassword = false }
      if !guest && !rememberPassword { reconnectOnNetworkReturn = false }
      selection = min(selection, controls.count - 1)
    case .rememberPassword:
      rememberPassword.toggle()
      if !rememberPassword && !guest { reconnectOnNetworkReturn = false }
    case .networkRecovery:
      if !guest && !rememberPassword {
        message = "请先选择记住密码，或使用访客访问"
      } else {
        reconnectOnNetworkReturn.toggle()
      }
    case .saveProfile: saveProfile()
    case .savedConnections:
      phase = "profiles"
      selection = 0
    case .newConnection: newConnection()
    case .profile(let id): selectProfile(id)
    case .deleteProfile:
      phase = "confirmDelete"
      selection = 1
      message = "删除此连接及 MacTV 为它保存的密码。"
    case .confirmDelete: deleteProfile()
    case .cancelDelete:
      phase = "form"
      selection = 0
      message = ""
    case .connect: connect()
    case .connectRoot:
      do {
        address = try SMBLocation(address).shareURL.absoluteString
        connect()
      } catch { message = error.localizedDescription }
    case .close: close()
    case .parent:
      if let directory { browse(directory.deletingLastPathComponent()) }
    case .folder(let url): browse(url)
    case .useDirectory:
      guard let share, let directory else { return }
      useDirectory(share: share, directory: directory)
    case .retryDirectory:
      if let attemptedDirectory { browse(attemptedDirectory) }
    case .browseRoot:
      if let share { browse(share.mount) }
    case .failureDetails:
      if let failure { onFailureDetails?((failure.errorDescription ?? "无法访问共享") + "\n\n" + failure.diagnostic) }
    case .reconnect:
      if let share { Task { await SMBMountClient.disconnect(share) } }
      share = nil; directory = nil; folders = []; attemptedDirectory = nil
      phase = "form"; selection = 0
    }
  }
  func connect() {
    guard !directoryReadPending else {
      message = "前一次目录读取尚未结束，未发起新的连接。请先处理系统提示或等待读取结束。"; failed(); return
    }
    failure = nil
    do {
      let location = try SMBLocation(address)
      let draft = try draftProfile()
      let supplied = password
      password = ""
      let credentialStore = credentialStore
      let mayLoad = storedPasswordAvailable
      if let id = activeProfileID, let old = profiles.first(where: { $0.id == id }),
        !draft.sameAccount(as: old)
      {
        activeProfileID = nil
      }
      let attempt = UUID()
      generation = attempt
      phase = "connecting"
      message = "正在连接…"
      selection = 0
      operation?.cancel()
      operation = Task {
        do {
          var secret = supplied
          if !draft.guest && secret.isEmpty && draft.rememberPassword {
            guard mayLoad else { throw MTVError.message("服务器、共享或账号已改变，请重新输入密码") }
            secret = try await Task.detached { try credentialStore.load(for: draft) ?? "" }.value
          }
          guard generation == attempt, isPresented, !Task.isCancelled else { return }
          if CommandLine.arguments.contains("--ui-smoke"), let connectionObserverForTesting {
            connectionObserverForTesting(location, draft.username, secret, draft.guest)
            phase = "form"
            message = "测试连接参数已记录，未发起网络访问"
            return
          }
          client.start(
            location: location, username: draft.username, password: secret, guest: draft.guest
          ) {
            [weak self] result in
            guard let self, self.generation == attempt, self.isPresented else { return }
            switch result {
            case .success(let share):
              self.password = ""
              self.share = share
              self.connectedProfile = self.activeProfileID == draft.id ? draft : nil
              self.browse(share.directory)
            case .failure(let error):
              self.phase = "form"
              self.recordFailure(error, stage: .mount)
              self.selection = 0
              self.failed()
            }
          }
        } catch {
          guard generation == attempt, isPresented else { return }
          phase = "form"
          recordFailure(error, stage: .mount)
          failed()
        }
      }
    } catch {
      message = error.localizedDescription
      failed()
    }
  }
  private func draftProfile() throws -> SMBProfile {
    try SMBProfile(
      id: activeProfileID ?? UUID(), address: address, username: username,
      guest: guest, rememberPassword: rememberPassword,
      reconnectOnNetworkReturn: reconnectOnNetworkReturn)
  }
  func newConnection() {
    activeProfileID = nil
    address = ""
    username = ""
    password = ""
    guest = false
    rememberPassword = false
    reconnectOnNetworkReturn = false
    phase = "form"
    message = ""
    selection = 0
    formTouched = true
  }
  func selectProfile(_ id: UUID) {
    guard let profile = profiles.first(where: { $0.id == id }) else { return }
    activeProfileID = id
    address = profile.address
    username = profile.username
    guest = profile.guest
    rememberPassword = profile.rememberPassword
    reconnectOnNetworkReturn = profile.reconnectOnNetworkReturn == true
    password = ""
    phase = "form"
    message = ""
    failure = nil
    formTouched = true
    selection = controls.firstIndex(of: guest || rememberPassword ? .connect : .password) ?? 0
  }
  func saveProfile() {
    guard phase == "form" else { return }
    do {
      let profile = try draftProfile()
      let old = profiles.first { $0.id == profile.id }
      let secret = password
      if profile.rememberPassword && secret.isEmpty {
        guard let old, old.rememberPassword, profile.sameAccount(as: old) else {
          throw MTVError.message("请输入密码，或关闭记住密码")
        }
      }
      let store = profileStore
      let vault = credentialStore
      generation = UUID()
      profilesLoading = false
      let attempt = generation
      let previous = saveTask
      phase = "saving"
      message = "正在保存连接…"
      selection = 0
      saveTask = Task {
        await previous?.value
        do {
          _ = try await store.load()
          if profile.rememberPassword && !secret.isEmpty {
            try await Task.detached { try vault.save(secret, for: profile) }.value
          } else if !profile.rememberPassword && old?.rememberPassword == true {
            try await Task.detached { try vault.remove(profileID: profile.id) }.value
          }
          let values = try await store.upsert(profile)
          guard generation == attempt, isPresented else { return }
          profiles = values
          activeProfileID = profile.id
          onProfileSaved?(profile)
          password = ""
          phase = "form"
          selection = controls.firstIndex(of: .connect) ?? 0
          message = "连接已保存；点击连接后访问共享"
        } catch {
          guard generation == attempt, isPresented else { return }
          phase = "form"
          message = L("连接未保存：\(error.localizedDescription)")
          selection = 0
        }
      }
    } catch { message = error.localizedDescription }
  }
  private func deleteProfile() {
    guard let id = activeProfileID, let profile = profiles.first(where: { $0.id == id }) else {
      return
    }
    let store = profileStore
    let vault = credentialStore
    let attempt = generation
    let previous = saveTask
    phase = "saving"
    message = "正在删除已保存连接…"
    selection = 0
    saveTask = Task {
      await previous?.value
      do {
        if profile.rememberPassword {
          try await Task.detached { try vault.remove(profileID: id) }.value
        }
        let values = try await store.remove(id)
        guard generation == attempt, isPresented else { return }
        profiles = values
        newConnection()
        phase = values.isEmpty ? "form" : "profiles"
      } catch {
        guard generation == attempt, isPresented else { return }
        phase = "form"
        message = L("连接未删除：\(error.localizedDescription)")
      }
    }
  }
  private func useDirectory(share: MountedSMBShare, directory: URL) {
    readDirectory(directory, allowedRoot: share.mount, verifying: share, selecting: true)
  }
  private func saveSelectedDirectory(share: MountedSMBShare, selected: SMBDirectorySelection) {
    guard let id = activeProfileID, var profile = profiles.first(where: { $0.id == id }) else {
      handOff(share: share, directory: selected.directory)
      return
    }
    do {
      let location = try SMBLocation(profile.address)
      var parts = URLComponents(url: location.shareURL, resolvingAgainstBaseURL: false)!
      parts.path += selected.relativePath
      profile.address = try SMBProfile.canonicalAddress(parts.url!.absoluteString)
      let saved = profile
      let store = profileStore
      let attempt = generation
      let previous = saveTask
      phase = "saving"
      message = "正在记住影片目录…"
      selection = 0
      saveTask = Task {
        await previous?.value
        guard generation == attempt, isPresented else { return }
        do {
          try share.validateCurrentMount()
          let values = try await store.upsert(saved)
          guard generation == attempt, isPresented else { return }
          profiles = values
          handOff(share: share, directory: selected.directory)
        } catch {
          guard generation == attempt, isPresented else { return }
          phase = "browseError"
          recordFailure(error, stage: .directoryVerification)
          failed()
        }
      }
    } catch {
      phase = "browseError"
      recordFailure(error, stage: .directoryVerification)
      failed()
    }
  }
  private func handOff(share: MountedSMBShare, directory: URL) {
    do { try share.validateCurrentMount() }
    catch { phase = "browseError"; recordFailure(error, stage: .mountValidation); failed(); return }
    let profile = profiles.first { $0.id == activeProfileID }.flatMap { candidate in
      connectedProfile.map { candidate.sameAccount(as: $0) } == true ? candidate : nil
    }
    self.share = nil
    password = ""
    isPresented = false
    onSelect?(share, directory, profile)
  }
  func waitForPendingSaves() async { await saveTask?.value }
  func reconnectAutomatically(expected: SMBProfile) {
    present(profileID: expected.id, automatic: expected)
  }
  private func failed() {
    let automatic = automaticExpected != nil
    automaticExpected = nil
    onConnectionFailure?(automatic)
  }
  func back() {
    if phase == "browse", let directory, let share, directory.path != share.mount.path {
      browse(directory.deletingLastPathComponent())
    } else if phase == "confirmDelete" {
      phase = "form"
      message = ""
      selection = 0
    } else if phase == "form" && !profiles.isEmpty {
      phase = "profiles"
      message = ""
      password = ""
      selection = 0
    } else {
      close()
    }
  }
  private func browse(_ url: URL) {
    guard let share else { return }
    readDirectory(url, allowedRoot: share.mount, verifying: share)
  }
  private func readDirectory(_ url: URL, allowedRoot: URL, verifying share: MountedSMBShare? = nil, selecting: Bool = false) {
    guard !directoryReadPending else {
      phase = "browseError"; message = "前一次目录读取尚未结束，未创建新的读取任务。"; return
    }
    let attempt = UUID()
    generation = attempt
    attemptedDirectory = url; failure = nil
    directoryReadID = attempt; directoryReadPending = true
    phase = "loading"
    message = selecting ? "正在核对影片目录…可以返回，结果就绪后再继续。" : ""
    selection = 0
    browseTimeout?.cancel()
    let deadline = CommandLine.arguments.contains("--ui-smoke") ? (directoryDeadlineForTesting ?? 15) : 15
    browseTimeout = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(max(0.01, min(15, deadline)))) } catch { return }
      guard let self, self.generation == attempt, self.phase == "loading" else { return }
      self.generation = UUID()
      self.phase = "browseError"
      self.recordFailure(NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT)), stage: selecting ? .directoryVerification : .directoryRead)
      self.failed()
    }
    Task {
      defer { finishDirectoryOperation(attempt) }
      do {
        let result: (directory: URL, folders: [URL])
        var selected: SMBDirectorySelection?
        if selecting {
          let resolver = CommandLine.arguments.contains("--ui-smoke") ? directorySelectionResolverForTesting : nil
          selected = try await Task.detached(priority: .utility) {
            let resolve = { try resolver?(url, allowedRoot) ?? SMBDirectoryAccess.selection(in: url, allowedRoot: allowedRoot) }
            if let share { return try share.withCurrentMount(resolve) }
            return try resolve()
          }.value
          result = (selected!.directory, [])
        } else if CommandLine.arguments.contains("--ui-smoke"), let directoryReaderForTesting {
          result = try await directoryReaderForTesting(url, allowedRoot)
        } else {
          result = try await Task.detached(priority: .utility) {
            if let share { return try share.withCurrentMount { try SMBDirectoryAccess.children(in: url, allowedRoot: allowedRoot) } }
            return try SMBDirectoryAccess.children(in: url, allowedRoot: allowedRoot)
          }.value
        }
        guard generation == attempt, isPresented else { return }
        browseTimeout?.cancel()
        browseTimeout = nil
        if let selected {
          if let share { saveSelectedDirectory(share: share, selected: selected) }
          else if CommandLine.arguments.contains("--ui-smoke") {
            phase = "form"; message = "测试目录核对完成，未建立或交接共享挂载。"
            onDirectorySelectionForTesting?(selected)
          }
          return
        }
        directory = result.0
        folders = result.1
        phase = "browse"
        message = ""
        failure = nil
        if automaticExpected != nil, let share {
          finishDirectoryOperation(attempt)
          useDirectory(share: share, directory: result.0)
        }
      } catch {
        guard generation == attempt, isPresented else { return }
        browseTimeout?.cancel()
        browseTimeout = nil
        phase = "browseError"
        recordFailure(error, stage: selecting ? .directoryVerification : .directoryRead)
        failed()
      }
    }
  }
  private func finishDirectoryOperation(_ attempt: UUID) {
    guard directoryReadID == attempt else { return }
    let selected = phase == "browseError" && controls.indices.contains(selection) ? controls[selection] : nil
    directoryReadID = nil; directoryReadPending = false
    if let selected, let index = controls.firstIndex(of: selected) { selection = index }
  }
  func close(notify: Bool = true) {
    let wasPresented = isPresented
    if notify && wasPresented && automaticExpected != nil { failed() }
    browseTimeout?.cancel()
    browseTimeout = nil
    generation = UUID()
    operation?.cancel()
    profilesLoading = false
    client.cancel()
    if let share { Task { await SMBMountClient.disconnect(share) } }
    share = nil
    connectedProfile = nil
    automaticExpected = nil
    password = ""
    folders = []
    directory = nil
    attemptedDirectory = nil; failure = nil
    isPresented = false
    if wasPresented && notify { onDismiss?() }
  }
  private func recordFailure(_ error: Error, stage: SMBFailure.Stage) {
    let evidence = SMBFailure(error, stage: stage); failure = evidence
    logger.notice("SMB failure; category=\(evidence.category.rawValue, privacy: .public) codes=\(evidence.diagnostic, privacy: .public)")
    message = error is MTVError ? error.localizedDescription : (evidence.errorDescription ?? "无法读取共享")
  }
  func showFailureForTesting(_ error: Error, stage: SMBFailure.Stage) {
    guard CommandLine.arguments.contains("--ui-smoke") else { return }
    present(); recordFailure(error, stage: stage)
    if stage == .mountValidation { phase = "browseError" }
  }
  func readDirectoryForTesting(_ url: URL, allowedRoot: URL) {
    guard CommandLine.arguments.contains("--ui-smoke") else { return }
    readDirectory(url, allowedRoot: allowedRoot)
  }
  func selectDirectoryForTesting(_ url: URL, allowedRoot: URL) {
    guard CommandLine.arguments.contains("--ui-smoke") else { return }
    readDirectory(url, allowedRoot: allowedRoot, selecting: true)
  }
}

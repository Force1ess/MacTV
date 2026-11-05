import AppKit
import MTVCore

/// Public launch and window metadata APIs. The selected application remains
/// responsible for its own login, content and rendering.
@MainActor final class ExternalAppSession: ObservableObject {
  @Published private(set) var phase = "idle"
  @Published private(set) var pluginID: String?
  @Published private(set) var message = ""
  @Published private(set) var observedWindowID: Int?
  @Published private(set) var familyProcesses = 0
  @Published private(set) var windowObservations: [[String:Any]] = []
  private var observation: Task<Void, Never>?
  private var generation = UUID()
  var onIssue: ((String) -> Void)?
  private var selectedBundleID: String?
  private var selectedLaunch: PluginAppLaunch?
  @Published private(set) var presentationRequest="none"
  func closeObservedWindow() async -> Bool {
    guard let declaration=selectedLaunch, let titles=declaration.windowTitles, !titles.isEmpty else { return false }
    let roots=NSWorkspace.shared.runningApplications.filter{$0.bundleIdentifier==declaration.bundleID}
    let pids=ApplicationProcessFamily.descendants(of:Set(roots.map(\.processIdentifier)))
    return await Task.detached(priority:.utility) { ApplicationAccessibility.perform(pids:pids,titles:titles,action:"close") }.value
  }
  func inspectAccessibility() async -> [String:Any] {
    guard let selectedBundleID else { return ["available":false,"reason":"no-selected-application"] }
    let applications=NSWorkspace.shared.runningApplications.filter{$0.bundleIdentifier==selectedBundleID}
    let pids=ApplicationProcessFamily.descendants(of:Set(applications.map(\.processIdentifier)))
    return await Task.detached(priority:.utility) { ApplicationAccessibility.inspect(pids:pids) }.value
  }
  func cancel(pluginID: String) {
    guard self.pluginID == pluginID else { return }
    observation?.cancel(); observation = nil; generation = UUID()
    phase = "idle"; self.pluginID = nil; message = ""
    selectedBundleID=nil; selectedLaunch=nil; presentationRequest="none"
    observedWindowID = nil; familyProcesses = 0; windowObservations = []
  }
  func launch(_ plugin: PluginRecord) {
    guard let declaration = plugin.manifest.applicationLaunch,
      (try? plugin.manifest.validate()) != nil, let url = URL(string: declaration.url) else { return }
    observation?.cancel(); generation = UUID(); let attempt = generation
    pluginID = plugin.id; message = ""
    selectedBundleID=declaration.bundleID; selectedLaunch=declaration; presentationRequest="none"
    guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: declaration.bundleID) else {
      phase = "not-installed"; message = "Install \(plugin.title) on this Mac to use this module."; return
    }
    phase = "launching"
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    if declaration.readyWhen=="visible-window" {
      NSWorkspace.shared.openApplication(at:app,configuration:configuration) { [weak self] _,error in
        Task { @MainActor in
          guard let self, self.generation==attempt else { return }
          if error != nil { self.phase="launch-failed"; self.message=L("The application could not be opened."); self.onIssue?(self.message); return }
          self.waitForReadyWindow(declaration:declaration,app:app,url:url,attempt:attempt)
        }
      }
      return
    }
    NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration) { [weak self] _, error in
      Task { @MainActor in
        guard let self, self.generation == attempt else { return }
        if error != nil { self.phase = "launch-failed"; self.message = L("The application could not open this action."); self.onIssue?(self.message); return }
        self.watch(declaration:declaration, app: app, attempt: attempt)
      }
    }
  }
  private func waitForReadyWindow(declaration: PluginAppLaunch, app: URL, url: URL, attempt: UUID) {
    phase="waiting-for-application"
    observation=Task { [weak self] in
      let deadline=ProcessInfo.processInfo.systemUptime+30
      while !Task.isCancelled {
        guard let self, generation==attempt else { return }
        let roots=NSWorkspace.shared.runningApplications.filter{$0.bundleIdentifier==declaration.bundleID}
        let pids=ApplicationProcessFamily.descendants(of:Set(roots.map(\.processIdentifier)))
        let windows=CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]] ?? []
        let ready=windows.contains { item in
          guard let pid=item[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid), item[kCGWindowLayer as String] as? Int==0,
            let raw=item[kCGWindowBounds as String] as? [String:Any], let bounds=CGRect(dictionaryRepresentation:raw as CFDictionary) else { return false }
          return bounds.width>=160 && bounds.height>=120
        }
        if ready {
          let configuration=NSWorkspace.OpenConfiguration(); configuration.activates=true
          NSWorkspace.shared.open([url],withApplicationAt:app,configuration:configuration) { [weak self] _,error in
            Task { @MainActor in
              guard let self, self.generation==attempt else { return }
              if error != nil { self.phase="launch-failed"; self.message=L("The application could not open this action."); self.onIssue?(self.message); return }
              self.watch(declaration:declaration,app:app,attempt:attempt)
            }
          }
          return
        }
        if ProcessInfo.processInfo.systemUptime>=deadline { phase="application-not-ready"; message=L("The application did not become ready. Complete its first setup, then try again."); onIssue?(message); return }
        do { try await Task.sleep(for:.milliseconds(200)) } catch { return }
      }
    }
  }
  private func watch(declaration: PluginAppLaunch, app: URL, attempt: UUID) {
    let bundleID = declaration.bundleID
    let matched=declaration.returnWhen=="matched-window-closes"
    if matched, !ApplicationAccessibility.available {
      phase="needs-accessibility"; message=L("Allow Accessibility access to observe this application's window and return automatically."); onIssue?(message); return
    }
    phase = matched ? "waiting-for-window":"waiting-for-fullscreen"
    observation = Task { [weak self] in
      // Include an already-running Big Picture window; reopening that mode may
      // reuse its window identifier instead of creating a new process/window.
      var tracker = FullscreenSessionTracker(baseline: [])
      let started = ProcessInfo.processInfo.systemUptime
      var presentationAttempts=Set<Int>(), transitionUntil=0.0, lastSelectedFront=false, unreadableSamples=0
      while !Task.isCancelled {
        guard let self, generation == attempt else { return }
        let applications = NSWorkspace.shared.runningApplications.filter {
          $0.bundleIdentifier == bundleID || $0.bundleURL?.path.hasPrefix(app.path + "/") == true
        }
        let pids = ApplicationProcessFamily.descendants(of:Set(applications.map(\.processIdentifier)))
        familyProcesses = pids.count
        let windows = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        windowObservations = windows.compactMap { value -> [String:Any]? in
          guard let pid = value[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
            let bounds = value[kCGWindowBounds as String] as? [String:Any] else { return nil }
          return ["pid":pid,"id":value[kCGWindowNumber as String] ?? 0,"bounds":bounds,
            "layer":value[kCGWindowLayer as String] ?? 0,"onscreen":value[kCGWindowIsOnscreen as String] ?? false]
        }
        let fullscreen = Set(windows.compactMap { value -> Int? in
          guard let pid = value[kCGWindowOwnerPID as String] as? Int32, pids.contains(pid),
            value[kCGWindowLayer as String] as? Int == 0,
            value[kCGWindowIsOnscreen as String] as? Bool == true,
            let raw = value[kCGWindowBounds as String] as? [String: Any],
            let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
            NSScreen.screens.contains(where: { abs($0.frame.width - bounds.width) < 12 && abs($0.frame.height - bounds.height) < 12 })
          else { return nil }
          return value[kCGWindowNumber as String] as? Int
        })
        let watched: Set<Int>
        if matched, applications.isEmpty { watched=[] }
        else if matched {
          let worker=Task.detached(priority:.utility) { ApplicationAccessibility.matchingWindows(pids:pids,titles:declaration.windowTitles ?? []) }
          let windows=await withTaskCancellationHandler(operation:{ await worker.value },onCancel:{worker.cancel()})
          guard generation==attempt, !Task.isCancelled else { return }
          guard let windows else {
            unreadableSamples += 1
            if unreadableSamples>=10 { phase="observation-unavailable"; message=L("The application's window could not be observed. Check Accessibility access."); onIssue?(message); return }
            do { try await Task.sleep(for:.milliseconds(500)) } catch { return }; continue
          }
          unreadableSamples=0
          watched=windows
        } else { watched=fullscreen }
        if watched.isEmpty, ProcessInfo.processInfo.systemUptime<transitionUntil { try? await Task.sleep(for:.milliseconds(300)); continue }
        tracker.observe(fullscreenWindows: watched, applicationRunning: !applications.isEmpty)
        observedWindowID = tracker.windowID
        if tracker.windowID != nil { phase = "active" }
        if matched, declaration.preferredPresentation=="fullscreen", let id=tracker.windowID, !presentationAttempts.contains(id) {
          presentationAttempts.insert(id)
          let worker=Task.detached(priority:.utility) { ApplicationAccessibility.perform(pids:pids,titles:declaration.windowTitles ?? [],action:"fullscreen") }
          let accepted=await withTaskCancellationHandler(operation:{await worker.value},onCancel:{worker.cancel()})
          guard generation==attempt, !Task.isCancelled else { return }
          presentationRequest=accepted ? "accepted":"unavailable"
          if accepted { transitionUntil=ProcessInfo.processInfo.systemUptime+2 }
        }
        if tracker.finished {
          let front = NSWorkspace.shared.frontmostApplication
          let hostFront=front?.processIdentifier==getpid()
          let selectedFront=front.map { current in applications.contains(where:{$0.processIdentifier==current.processIdentifier || (current.bundleURL != nil && $0.bundleURL != nil && current.bundleURL!.path.hasPrefix($0.bundleURL!.path+"/"))}) } ?? false
          let ownsFront = matched ? (selectedFront || hostFront):(front.map { pids.contains($0.processIdentifier) } ?? false)
          if ownsFront, !watched.isEmpty {
            tracker = FullscreenSessionTracker(baseline:[])
            tracker.observe(fullscreenWindows:watched,applicationRunning:true)
            continue
          }
          if matched, watched.isEmpty, !fullscreen.isEmpty { phase="waiting-for-application-return" }
          else if LauncherReturnPolicy.shouldActivate(applicationRunning:!applications.isEmpty,selectedApplicationFront:ownsFront,hostFront:hostFront,lastSelectedApplicationFront:lastSelectedFront) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.identifier?.rawValue == "MTVMainWindow" })?.makeKeyAndOrderFront(nil)
            phase = "returned"
            return
          } else if applications.isEmpty { phase="ended-in-background"; return }
          else { phase = "waiting-for-application-return" }
        }
        let front=NSWorkspace.shared.frontmostApplication
        lastSelectedFront=front.map { current in applications.contains(where:{$0.processIdentifier==current.processIdentifier || (current.bundleURL != nil && $0.bundleURL != nil && current.bundleURL!.path.hasPrefix($0.bundleURL!.path+"/"))}) } ?? false
        if tracker.windowID == nil, ProcessInfo.processInfo.systemUptime - started > 45 {
          phase = matched ? "window-not-observed":"fullscreen-not-observed"
          let language = Bundle.main.preferredLocalizations.first ?? "en"
          message = declaration.instructions?[language] ?? declaration.instructions?["en"] ?? L("The app is open. Complete its setup and enter fullscreen mode, then try again.")
          onIssue?(message); return
        }
        do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
      }
    }
  }
}

import AppKit
import Darwin
import Foundation
import OSLog
import SwiftUI
import MTVCore

let launchLog = Logger(subsystem: "local.mtv.preview", category: "launch")

@MainActor final class ApplicationLifecycle: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let model = AppModel()
  private var mainWindow: NSWindow?
  private var startupFullScreenPending = false
  private var control: AppControl?
  private var windowFocusObservers: [NSObjectProtocol] = []
  private var terminationSignal: DispatchSourceSignal?
  private var isTerminating = false
  private var readyToTerminate = false
  private var waitingForAppKitReply = false
  static private(set) var signalHandlerInstalled = false

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Handle an installer/terminal SIGTERM as a normal app quit, on the UI thread.
    // This applies only inside MTV; it does not alter system or other-app signal policy.
    signal(SIGTERM, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    source.setEventHandler { Task { @MainActor [weak self] in self?.beginTermination() } }
    source.resume()
    terminationSignal = source
    Self.signalHandlerInstalled = true
    // MPV owns a separate AppKit window. Observe process-local key-window
    // transitions instead of relying only on the main window's delegate.
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      windowFocusObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in self?.refreshPlaybackCursor() }
      })
    }
    startupFullScreenPending = !CommandLine.arguments.contains("--windowed")
      && !CommandLine.arguments.contains("--ui-smoke")
    showMainWindow()
    do { try RuntimeTestGuard.startGuardian() }
    catch { launchLog.error("Interactive test guardian could not start"); NSApp.terminate(nil); return }
    model.start()
    if CommandLine.arguments.contains("--enable-control") {
      let endpoint = AppControl(model: model, allowAccountImport: CommandLine.arguments.contains("--allow-account-import"))
      do { try endpoint.start(); control = endpoint }
      catch { launchLog.error("Local control could not start; GUI remains available") }
    }
    launchLog.notice("Explicit main window created; windows=\(NSApp.windows.count)")
    if let window = mainWindow {
      Task { @MainActor in
        if CommandLine.arguments.contains("--ui-smoke") {
          window.setContentSize(
            CommandLine.arguments.contains("--tv-layout")
              ? NSSize(width: 1280, height: 720) : NSSize(width: 1600, height: 1000))
          window.center()
          if CommandLine.arguments.contains("--documentation-preview") {
            do { try DocumentationPreview.prepare(model) }
            catch { launchLog.error("Documentation preview artwork could not be generated") }
          } else {
            await UISmoke.run(model: model, window: window)
            // Do not enter AppKit's terminate-later event loop while this
            // Swift MainActor task still owns the executor. Finish cleanup
            // before requesting the final, immediately accepted termination.
            if RuntimeTestGuard.installed, RuntimeTestGuard.supervisor != nil { beginTermination() }
          }
        }
      }
    }
  }
  func showMainWindow() {
    if mainWindow == nil {
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: 1600, height: 1000),
        styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered,
        defer: false)
      window.title = AppBrand.name
      window.acceptsMouseMovedEvents = true
      window.identifier = NSUserInterfaceItemIdentifier("MTVMainWindow")
      window.titleVisibility = .hidden
      window.titlebarAppearsTransparent = true
      window.backgroundColor = .black
      window.contentMinSize = NSSize(width: 1100, height: 700)
      window.isReleasedWhenClosed = false
      window.isRestorable = false
      window.collectionBehavior.insert(.fullScreenPrimary)
      window.delegate = self
      let hostingView = NSHostingView(rootView: RootView(model: model))
      if #unavailable(macOS 26.0) {
        // AppKit owns the window size on Sequoia. Avoid feeding SwiftUI's
        // scroll content measurements back into the window during resizing.
        hostingView.sizingOptions = []
      }
      window.contentView = hostingView
      window.center()
      mainWindow = window
    }
    NSApp.setActivationPolicy(.regular)
    if CommandLine.arguments.contains("--background-recovery") { mainWindow?.orderFront(nil) }
    else { mainWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
  }
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool
  {
    showMainWindow()
    return false
  }
  func applicationDidBecomeActive(_ notification: Notification) {
    refreshPlaybackCursor()
  }
  func applicationDidResignActive(_ notification: Notification) { TVPointerFocus.setPlaybackCursorHidden(false) }
  private func refreshPlaybackCursor() {
    let playbackWindowIsKey = NSApp.isActive && NSApp.keyWindow?.identifier?.rawValue == "MTVMainWindow"
    TVPointerFocus.setPlaybackCursorHidden(playbackWindowIsKey && model.playbackPresented && !model.playerControlsVisible)
  }
  func windowDidUpdate(_ notification: Notification) {
    guard startupFullScreenPending, let window = notification.object as? NSWindow,
      window === mainWindow, window.isVisible else { return }
    startupFullScreenPending = false
    // Enter full screen outside the first window update (issue #2).
    DispatchQueue.main.async { [weak self, weak window] in
      guard let self, let window, !self.isTerminating, window.isVisible,
        !window.styleMask.contains(.fullScreen) else { return }
      window.toggleFullScreen(nil)
    }
  }
  func windowWillClose(_ notification: Notification) { model.stopPlayback() }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if readyToTerminate { return .terminateNow }
    waitingForAppKitReply = true
    beginTermination()
    // Preserve the native Quit/logout contract. Our SIGTERM path prepares before
    // calling terminate(), so it never nests this wait inside its MainActor task.
    return .terminateLater
  }
  private func beginTermination() {
    guard !isTerminating else { return }
    isTerminating = true
    for observer in windowFocusObservers { NotificationCenter.default.removeObserver(observer) }
    windowFocusObservers.removeAll()
    TVPointerFocus.setPlaybackCursorHidden(false)
    control?.stop(); control = nil
    Task {
      _ = model.prepareForTermination()
      await model.waitForPlaybackShutdown()
      readyToTerminate = true
      if waitingForAppKitReply {
        NSApp.reply(toApplicationShouldTerminate: true)
      } else {
        NSApp.terminate(nil)
      }
    }
  }
}

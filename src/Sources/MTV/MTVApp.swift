import AppKit
import MTVCore
import SwiftUI
import Vision

@main struct MTVApp: App {
  @NSApplicationDelegateAdaptor(ApplicationLifecycle.self) private var lifecycle
  init() {
    RuntimeTestGuard.runGuardianIfRequested()
    if RuntimeTestGuard.installed, CommandLine.arguments.contains("--ui-smoke"), RuntimeTestGuard.supervisor == nil {
      fputs("Use tools/check/run-interactive-test.rb for tests on the installed app.\n",stderr); exit(64)
    }
    if CommandLine.arguments.contains("--chrome-quark-native-import") {
      ChromeQuarkImport.runNativeMessage(); exit(0)
    }
  }
  var body: some Scene {
    // The TV app owns one AppKit window; its entire interface remains SwiftUI.
    // A Settings scene supplies native app commands without a restorable main scene.
    Settings { EmptyView() }
      .commands {
        CommandGroup(replacing: .appSettings) {
          Button(L("\(AppBrand.name) 设置")) {
            lifecycle.showMainWindow()
            lifecycle.model.navigate(.settings)
          }.keyboardShortcut(",", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
          Button(L("显示主窗口")) { lifecycle.showMainWindow() }.keyboardShortcut("n", modifiers: .command)
          Button(L("返回首页")) { lifecycle.model.handle(.home) }.keyboardShortcut(
            "h", modifiers: .command)
          Button(L("搜索")) { lifecycle.model.showKeyboard() }.keyboardShortcut("f", modifiers: .command)
          Button(L("重新扫描影片")) { lifecycle.model.scanLibrary() }.keyboardShortcut(
            "r", modifiers: .command)
        }
      }
  }
}

@MainActor enum UISmoke {
  static func exitPlaybackWithRemote(model: AppModel) {
    if model.preparingPlayback { model.handle(.back); return }
    guard model.playbackPresented else { return }
    if model.playerControlsVisible, model.playbackInterruption == nil, !model.playbackCompleted { model.handle(.back) }
    if model.playbackPresented { model.handle(.back) }
  }
  static func run(model: AppModel, window: NSWindow) async {
    let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Application Support/MTV/TestResults", isDirectory: true)
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let runID = "run-" + formatter.string(from: Date()) + "-" + UUID().uuidString.prefix(8)
    let output = base.appendingPathComponent(runID, isDirectory: true)
    try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    // Replace the previous result immediately: a stalled new run must never look
    // like the last successful run. This contains no login or media credentials.
    let startedReport: [String: Any] = [
      "kind": "ui-smoke-running", "runDirectory": output.path,
      "pid": ProcessInfo.processInfo.processIdentifier,
    ]
    if let data = try? JSONSerialization.data(withJSONObject: startedReport, options: [.sortedKeys])
    {
      try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
    }
    var checks: [String: Bool] = [:]
    var playbackDiagnostics: [String: Any] = [:]
    if CommandLine.arguments.contains("--owned-regression") {
      // Explicit opt-in fixture scope; never a fallback for failed NAS access.
      // Ordinary/full NAS tests keep their original source initialization.
      do {
        let root = output.appendingPathComponent("initial-owned-library")
        let fixture = base.deletingLastPathComponent().appendingPathComponent("Fixtures/PlaybackFixture.mp4")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in ["A Test Movie (2024).mp4", "Example Show S01E01.mp4", "Example Show S01E02.mp4"] {
          try FileManager.default.copyItem(at: fixture, to: root.appendingPathComponent(name))
        }
        model.useLocalRoot(root)
        for _ in 0..<300 {
          if !model.libraryRefreshing { break }
          try? await Task.sleep(for: .milliseconds(40))
        }
        model.navigate(.home)
      } catch { checks["initialOwnedLibraryCreated"] = false }
    }
    if CommandLine.arguments.contains("--system-dictation-only") {
      var report = await systemDictationSmoke(model: model, window: window)
      report["kind"] = "ui-smoke"; report["pid"] = ProcessInfo.processInfo.processIdentifier; report["runDirectory"] = output.path
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--system-text-input-only") || CommandLine.arguments.contains("--source-management-only") || CommandLine.arguments.contains("--modern-playback-only") {
      let sources = CommandLine.arguments.contains("--source-management-only")
      if sources {
        checks = await tvRefinementSmoke(model: model, output: output, window: window)
        checks.merge(await localFolderSmoke(model: model, output: output, window: window)) { _, latest in latest }
        checks.merge(await savedSourcesSmoke(model: model, output: output, window: window)) { _, latest in latest }
      } else if CommandLine.arguments.contains("--system-text-input-only") { checks = await systemTextInputSmoke(model: model, output: output, window: window) }
      else { checks = await modernPlaybackSmoke(model: model, output: output, window: window) }
      let report: [String: Any] = ["kind": "ui-smoke", "scope": sources ? "source-management-only" : CommandLine.arguments.contains("--system-text-input-only") ? "system-text-input-only" : "modern-playback-only",
        "checks": checks, "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "ownedFixturesOnly": true,
        "realNASOrChromeSessionVerified": false, "physicalAudioOutputVerified": false, "macOSAudioTranscriptionVerified": false, "microphoneRecordingStartedByTest": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--playback-quality-only") {
      checks = await playbackQualitySmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "playback-quality-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "ownedFixturesOnly": true,
        "realPlatformQualityVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--library-organization-only") {
      checks = await libraryOrganizationSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "library-organization-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "ownedFixturesOnly": true,
        "physicalRemoteVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--library-maintenance-only") {
      checks = await libraryMaintenanceSmoke(model: model, output: output)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "library-maintenance-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "ownedFixturesOnly": true,
        "timerIntervalVerified": false, "realPlatformPosterMatchVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--player-timeline-only") {
      checks = await playerTimelineSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "player-timeline-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "ownedFixturesOnly": true,
        "verificationScope": "remote-action-routing-and-native-backend-clocks",
        "testedEngines": ["system", "mpv"],
        "requestedScopeFullyVerified": checks.filter { $0.key.hasSuffix("-nativeSliderDragSeeksBackend") && $0.value }.count == 2,
        "nativePointerDragVerified": checks.filter { $0.key.hasSuffix("-nativeSliderDragSeeksBackend") && $0.value }.count == 2,
        "physicalRemoteOrTouchpadVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--subtitle-handoff-only") {
      checks = await subtitleHandoffSmoke(model: model, output: output)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "subtitle-handoff-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "ownedFixturesOnly": true, "physicalHDROutputVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--default-playback-only") {
      checks = await defaultPlaybackSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "default-playback-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "ownedFixturesOnly": true, "physicalRemoteVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--chrome-login-only") {
      checks = await chromeLoginSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "chrome-login-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "realChromeCookiesRead": false,
        "realPlatformLoginVerified": false, "realKeychainRead": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--tv-refinement-only") {
      checks = await tvRefinementSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "tv-refinement-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "physicalRemoteVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--setup-guide-only") {
      checks = await setupGuideSmoke(model:model,output:output,window:window)
      let report: [String:Any] = ["kind":"ui-smoke","scope":"setup-guide-only","checks":checks,
        "pid":ProcessInfo.processInfo.processIdentifier,"runDirectory":output.path,
        "passed":!checks.isEmpty && checks.values.allSatisfy{$0},"noOSPermissionsChanged":true]
      if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
        try? data.write(to:output.appendingPathComponent("ui-smoke.json"),options:.atomic)
        try? data.write(to:base.appendingPathComponent("ui-smoke.json"),options:.atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--mpv-playback-only") {
      checks = await mpvPlaybackSmoke(model:model,output:output,window:window)
      let report: [String:Any] = ["kind":"ui-smoke","scope":"mpv-playback-only","checks":checks,
        "pid":ProcessInfo.processInfo.processIdentifier,"runDirectory":output.path,
        "passed":!checks.isEmpty && checks.values.allSatisfy{$0},"sourceMediaUnmodified":true]
      if let data = try? JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]) {
        try? data.write(to:output.appendingPathComponent("ui-smoke.json"),options:.atomic)
        try? data.write(to:base.appendingPathComponent("ui-smoke.json"),options:.atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--bilibili-account-only") {
      checks = await bilibiliAccountSmoke(model: model, output: output)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "bilibili-account-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "readOnlyProviderRequests": true]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--tv-experience-only") {
      checks = await tvExperienceSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "tv-experience-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "realChromeSessionImported": false,
        "physicalRemoteVerified": false, "dolbyColorVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--prefix-cache-only") {
      checks = await prefixCacheSmoke()
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "prefix-cache-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "generatedBytesOnly": true]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--playback-benchmark-only") {
      checks = await playbackBenchmarkRun(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "playback-benchmark-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "performanceBudgetApplied": false,
        "physicalDisplayVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--audio-output-only") {
      checks = await audioOutputSmoke(model: model, output: output)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "audio-output-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "hardwareAudioSinkReplaced": false,
        "televisionSpeakerAudibilityVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--rf64-audio-only") {
      checks = await rf64AudioSmoke(output: output)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "rf64-audio-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "generatedAudioOnly": true,
        "physicalAudioOutputVerified": false, "realLongCompressedMediaTested": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--system-audio-lifecycle-only") {
      checks = await systemAudioLifecycleSmoke(model: model, output: output)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "system-audio-lifecycle-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "ownedFixtureOnly": true,
        "physicalAudioOutputVerified": false, "realSMBMountTested": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--system-audio-stereo-only") {
      checks = await systemAudioStereoSmoke(model: model, output: output)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "system-audio-stereo-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "ownedFixtureOnly": true,
        "physicalAudioOutputVerified": false, "realSMBMountTested": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--system-audio-scoped-only") {
      checks = await systemAudioScopedSmoke(model: model, output: output)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "system-audio-scoped-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "ownedFixtureOnly": true,
        "physicalAudioOutputVerified": false, "realSMBMountTested": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--system-audio-session-only") {
      checks = await systemAudioSessionSmoke(model: model, output: output)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "system-audio-session-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "ownedFixtureOnly": true,
        "physicalAudioOutputVerified": false, "preciseLipSyncVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--system-audio-wave-only") {
      checks = await systemAudioWaveSmoke(output: output)
      checks.merge(await loopbackMediaSmoke()) { _, new in new }
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "system-audio-wave-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "ownedFixtureOnly": true,
        "nativeVLCPlaybackExecuted": false, "physicalAudioOutputVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--vlc-audio-content-only") {
      checks = await vlcAudioContentSmoke(model: model, output: output)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "vlc-audio-content-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "diagnosticCaptureOnly": true,
        "hardwareAudioOutputReplacedByTestSink": true, "physicalAudioOutputVerified": false, "preciseLipSyncVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--vlc-multi-edit-only") {
      checks = await vlcMultiEditSmoke(model: model, output: output)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "vlc-multi-edit-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "ownedEditedSampleOnly": true,
        "physicalAudioOutputVerified": false, "allMP4SeekVerified": false, "hdrOutputVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--vlc-resume-content-only") {
      checks = await vlcResumeContentSmoke(model: model, output: output)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "vlc-resume-content-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "diagnosticCollectionOnly": true,
        "generatedOwnedSamplesOnly": true, "editedMP4AccurateVLCResumeVerified": false, "hdrOutputVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--smb-failure-only") {
      checks = await smbFailureSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "smb-failure-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "actualSMBMount": false,
        "networkRequested": false, "realNASAuthorizationVerified": false, "onlyOwnedLocalDirectoryAndInjectedErrors": true]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--watchlist-only") {
      checks = await watchlistSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "watchlist-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "generatedLocalFixtures": true,
        "realAccountAuthorizationVerified": false, "realNASAuthorizationVerified": false,
        "physicalAudioOutputVerified": false, "physicalRemoteVerified": false,
        "liveServices": CommandLine.arguments.contains("--live-services"),
        "coldStartRead": CommandLine.arguments.contains("--watchlist-cold-read"), "coldStartWrite": CommandLine.arguments.contains("--watchlist-cold-write")]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--plugin-registry-recovery-only") {
      checks = await pluginRegistryRecoverySmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "plugin-registry-recovery-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "externalNetworkRequested": false,
        "onlyPrivatePluginFixtureUsed": true, "realAccountAuthorizationVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--module-lookup-only") {
      checks = await moduleLookupSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "module-lookup-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "liveServices": CommandLine.arguments.contains("--live-services"),
        "realAccountAuthorizationVerified": false, "physicalAudioOutputVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--history-recovery-only") {
      checks = await historyRecoverySmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "history-recovery-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "externalNetworkRequested": false,
        "onlyPrivatePreferenceFixtureUsed": true]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--artwork-formats-only") {
      checks = await artworkFormatsSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "artwork-formats-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "generatedLocalFixtures": true,
        "physicalScreenVerified": false, "realNASAuthorizationVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--continue-watching-only") {
      checks = await continueWatchingSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "continue-watching-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "externalNetworkRequested": false,
        "realNASAuthorizationVerified": false, "physicalRemoteTested": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--playback-resume-mismatch-only") {
      checks = await playbackResumeMismatchSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "playback-resume-mismatch-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "externalNetworkRequested": false,
        "editedMP4AccurateVLCResumeVerified": false, "nativeReaderDiagnosticOverride": CommandLine.arguments.contains("--test-vlc-native-reader"), "physicalAudioOutputVerified": false, "hdrOutputTested": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--playback-resume-only") {
      checks = await playbackResumeSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "playback-resume-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "externalNetworkRequested": false,
        "physicalAudioOutputVerified": false, "hdrOutputTested": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--module-recovery-only") {
      checks = await moduleRecoverySmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "module-recovery-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "externalNetworkRequested": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--module-parts-only") {
      checks = await modulePartsSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "module-parts-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 },
        "externalNetworkRequested": CommandLine.arguments.contains("--live-services"), "realAccountAuthorizationVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--plugin-broker-live-only") {
      checks = await pluginBrokerLiveSmoke(model: model)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "plugin-broker-live-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "realAccountAuthorizationVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--plugin-install-only") {
      if CommandLine.arguments.contains("--plugin-cold-read") { checks = await pluginInstallColdRead(model: model) }
      else { checks = await pluginInstallSmoke(model: model, output: output, window: window) }
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "plugin-install-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "generatedOwnPlugin": true,
        "hostSandboxSignatureChecked": true, "completeIsolationAuditPassed": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--artwork-refresh-only") {
      checks = await artworkRefreshSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "artwork-refresh-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "generatedLocalFixtures": true, "physicalScreenVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--metadata-failure-only") {
      checks = await metadataFailureSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "metadata-failure-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "generatedLocalFixtures": true, "realNASPlaybackVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--incremental-library-only") {
      checks = await incrementalLibrarySmoke(model: model, output: output)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "incremental-library-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "generatedLocalFixtures": true, "realNASPlaybackVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--library-browse-only") {
      checks = await libraryBrowseSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "library-browse-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "generatedLocalFixtures": true,
        "realNASAuthorizationVerified": false, "physicalRemoteVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--module-continuation-only") {
      checks = await moduleContinuationSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "module-continuation-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "realAccountAuthorizationVerified": false,
        "physicalAudioOutputVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--next-episode-only") {
      checks = await episodeContinuationSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "next-episode-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "generatedLocalFixtures": true,
        "realNASAuthorizationVerified": false, "physicalRemoteVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--local-subtitles-only") {
      checks = await localSubtitlesSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "local-subtitles-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "generatedLocalFixtures": true,
        "realNASAuthorizationVerified": false, "physicalDisplayOutputVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--playback-tracks-only") {
      checks = await playbackTracksSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "playback-tracks-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "generatedLocalFixtures": true,
        "physicalAudioOutputVerified": false, "externalSubtitleImportVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--movie-versions-only") {
      checks = await movieVersionsSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "movie-versions-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "realNASPlaybackVerified": false, "generatedLocalFixtures": true]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--library-overview-only") {
      checks = await libraryOverviewSmoke(model: model, output: output, window: window)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "library-overview-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 },
        "realNASPlaybackVerified": false, "generatedLocalFixtures": true]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--playback-recovery-only") {
      checks = await playbackRecoverySmoke(model: model, window: window, output: output)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "playback-recovery-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 },
        "realNetworkDisconnectionVerified": false, "physicalRemoteVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    var moduleDiagnostics: [String: String] = [:]
    let savedEngineChoice = model.preferredEngine
    model.preferredEngine = .system
    defer { model.preferredEngine = savedEngineChoice }
    if CommandLine.arguments.contains("--loopback-media-only") {
      checks = await loopbackMediaSmoke()
      checks.merge(await indexedRangeSmoke(output: output)) { _, latest in latest }
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "loopback-media-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "externalNetworkRequested": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--split-playback-only") {
      checks = await splitPlaybackSmoke(model: model, output: output)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "split-playback-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 }, "realPlatformPlaybackVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--bilibili-playback-only") {
      let result = await bilibiliPlaybackOnly(model: model, output: output)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "bilibili-playback-only",
        "checks": result.checks, "diagnostics": result.diagnostics,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": !result.checks.isEmpty && result.checks.values.allSatisfy { $0 }]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--remote-header-only") {
      checks = await remoteHeaderSmoke(model: model, output: output)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "remote-header-only",
        "checks": checks, "pid": ProcessInfo.processInfo.processIdentifier,
        "runDirectory": output.path, "passed": !checks.isEmpty && checks.values.allSatisfy { $0 },
        "realPlatformPlaybackVerified": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--smb-app-persist-write") || CommandLine.arguments.contains("--smb-app-persist-read") {
      let arguments = CommandLine.arguments
      let scope = arguments.firstIndex(of: "--smb-app-persist-scope").flatMap {
        $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
      } ?? ""
      let write = arguments.contains("--smb-app-persist-write")
      let result = await smbProfilePersistence(scope: scope, write: write)
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "smb-app-persistence",
        "mode": write ? "write" : "read-and-clean", "checks": result.checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": result.error == nil && !result.checks.isEmpty && result.checks.values.allSatisfy { $0 },
        "error": result.error ?? "", "networkRequested": false, "realCredentialRead": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--session-probe-only") {
      let arguments = CommandLine.arguments
      let scope =
        arguments.firstIndex(of: "--persist-scope").flatMap {
          $0 + 1 < arguments.count ? arguments[$0 + 1] : nil
        } ?? ""
      let write = arguments.contains("--test-session-persist-write")
      let result = await Task.detached { sessionPersistence(scope: scope, write: write) }.value
      let report: [String: Any] = [
        "kind": "session-persistence", "checks": result.checks,
        "passed": result.error == nil && result.checks.values.allSatisfy { $0 },
        "error": result.error ?? "", "runDirectory": output.path,
        "persistenceProbe": write ? "write" : "read-and-clean", "scope": scope,
        "realAccountRead": false,
      ]
      if let data = try? JSONSerialization.data(
        withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
      {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--test-keychain") {
      let result = await Task.detached { keychainRoundtrip() }.value
      checks["keychainOwnRecordRoundtrip"] =
        result.error == nil && result.checks.values.allSatisfy { $0 }
      moduleDiagnostics["keychain"] = result.error ?? "仅本应用的临时测试记录通过，未读取真实账号"
    }
    for _ in 0..<100 {
      if !model.loading { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    checks["libraryLoaded"] = !model.library.isEmpty
    model.notice = nil
    if CommandLine.arguments.contains("--smb-offline-startup-read") {
      let arguments = CommandLine.arguments
      let scope = arguments.firstIndex(of: "--smb-offline-test-scope").flatMap {
        $0 + 1 < arguments.count ? UUID(uuidString: arguments[$0 + 1]) : nil
      }
      checks = ["smbColdStartupHasOfflineCatalog": model.needsSMBReconnect && model.library.count == 1,
        "smbColdStartupHasNoTransientFileURL": model.library.allSatisfy { $0.url == nil && $0.localMetadata?.sourceReachable == false },
        "smbColdStartupKeepsNASSource": model.mediaRoot.isEmpty && model.hasLibrarySource && !model.sourceNeedsSetup,
        "smbColdStartupRestoresExpectedIdentity": scope.map { id in model.library.first?.id.contains(id.uuidString.lowercased()) == true } == true]
      if let address = model.library.first?.poster, let url = URL(string: address) {
        let image = await ArtworkCache.shared.image(for: url)
        checks["smbColdStartupPosterDecodesWithoutOriginalMount"] = image != nil
        checks["smbColdStartupPosterMakesNoNetworkRequest"] = await ArtworkCache.shared.networkRequests() == 0
      } else { checks["smbColdStartupPosterDecodesWithoutOriginalMount"] = false }
      await settle()
      capture(window, to: output.appendingPathComponent("34-cold-nas-startup.png"))
      let report: [String: Any] = ["kind": "ui-smoke", "scope": "smb-offline-cold-startup", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier, "runDirectory": output.path,
        "passed": checks.values.allSatisfy { $0 }, "smbNetworkAccessVerified": false,
        "oldMountDirectoryRequired": false]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--fresh-install-smoke") {
      checks = await sourceSetupSmoke(model: model, output: output, window: window)
      let report: [String: Any] = [
        "kind": "ui-smoke", "scope": "fresh-install", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 },
        "runDirectory": output.path, "realSourcePreferencesModified": false,
        "physicalRemoteTested": false, "smbNetworkAccessVerified": false,
      ]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    if CommandLine.arguments.contains("--local-folders-only") {
      checks = await localFolderSmoke(model: model, output: output, window: window)
      let report: [String: Any] = [
        "kind": "ui-smoke", "scope": "local-folders-only", "checks": checks,
        "pid": ProcessInfo.processInfo.processIdentifier,
        "passed": !checks.isEmpty && checks.values.allSatisfy { $0 },
        "runDirectory": output.path, "physicalRemoteTested": false,
        "nativeWindowKeyRouteVerified": checks["localFolderNativeWindowKeyRoute"] == true,
      ]
      if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
        try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
        try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
      }
      return
    }
    await settle()
    capture(window, to: output.appendingPathComponent("01-home.png"))
    model.focus.select(row: 0, column: 0)
    let heroIsCollection = model.selectedHero?.isLibraryCollection == true
    model.handle(.down)
    model.handle(.select)
    checks["heroRemoteAction"] =
      heroIsCollection
      ? (model.libraryPath.count == 1 && model.section == .library) : (model.playbackPresented || model.preparingPlayback)
    if model.playbackPresented || model.preparingPlayback { exitPlaybackWithRemote(model: model) }
    else { model.handle(.back) }
    model.focus.select(row: 2, column: 0)
    model.handle(.select)
    checks["homeAppRemoteAction"] = model.section == .library
    model.navigate(.library)
    model.focus.select(row: 1, column: 0)
    model.handle(.select)
    checks["keyboardOpened"] = model.keyboardVisible
    for _ in 0..<150 {
      if model.pinyin.ready || model.pinyin.failure != nil { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    checks["rimeEngineReady"] = model.pinyin.ready
    model.chinese = true
    model.pressKey("N")
    model.pressKey("I")
    checks["pinyinCandidate"] = model.candidates.contains("你")
    model.handle(.up)
    model.candidateIndex = model.candidates.firstIndex(of: "你") ?? 0
    model.handle(.select)
    checks["candidateCommitted"] = model.search == "你"
    model.pressKey("清空")
    model.handle(.text("tianqihenhao"))
    model.candidateFocus = true
    model.candidateIndex = model.candidates.firstIndex(of: "天气很好") ?? 0
    await settle()
    capture(window, to: output.appendingPathComponent("15-rime-candidates.png"))
    model.handle(.select)
    checks["rimeSentenceCommitted"] = model.search == "天气很好" && model.composing.isEmpty
    model.pressKey("清空")
    model.handle(.text("shi"))
    let firstPage = model.candidates
    model.candidateFocus = true
    model.candidateIndex = model.candidates.count
    model.handle(.select)
    checks["rimeRemoteNextPage"] = model.pinyin.state.page == 1 && model.candidates != firstPage
    model.candidateIndex = model.candidates.count
    model.handle(.select)
    checks["rimeRemotePreviousPage"] = model.pinyin.state.page == 0 && model.candidates == firstPage
    model.pressKey("清空")
    for key in ["X", "I", "'", "A", "N"] { model.pressKey(key) }
    model.candidateFocus = true
    model.candidateIndex = model.candidates.firstIndex(of: "西安") ?? 0
    model.handle(.select)
    checks["rimeOnScreenSyllableSeparator"] = model.search == "西安"
    model.pressKey("清空")
    model.handle(.text("wojintianxiangqukandianying"))
    model.candidateFocus = true
    model.candidateIndex = model.candidates.firstIndex(of: "我今天") ?? 0
    model.handle(.select)
    checks["rimePartialSelectionRetained"] = model.composing.contains("我今天") && model.search.isEmpty
    model.candidateIndex = model.candidates.firstIndex(of: "想去看电影") ?? 0
    model.handle(.select)
    checks["rimeSegmentedSentenceCommitted"] = model.search == "我今天想去看电影" && model.composing.isEmpty
    model.pressKey("清空")
    model.chinese = false
    model.uppercase = false
    model.pressKey("A")
    model.pressKey("大小写")
    model.pressKey("B")
    model.pressKey(".")
    checks["keyboardSymbolsAndCase"] = model.search == "aB."
    model.pressKey("清空")
    model.chinese = true
    model.uppercase = false
    await settle()
    capture(window, to: output.appendingPathComponent("02-keyboard.png"))
    model.handle(.back)
    checks["keyboardClosed"] = !model.keyboardVisible
    model.search = ""
    model.rebuildFocus()
    if let movieIndex = model.visibleItems.firstIndex(where: { !$0.isLibraryCollection }) {
      model.focus.select(row: 2 + movieIndex / 6, column: movieIndex % 6)
      model.selectContent(model.visibleItems[movieIndex])
      checks["detailOpened"] = model.detail != nil
      await settle()
      capture(window, to: output.appendingPathComponent("03-detail.png"))
      model.handle(.back)
      checks["detailClosed"] = model.detail == nil
    } else {
      // Permission/empty-library failures remain failures in the report, rather
      // than indexing an empty array and killing the entire test process.
      checks["detailOpened"] = false; checks["detailClosed"] = false
    }
    let explicitMedia = CommandLine.arguments.firstIndex(of: "--test-media").flatMap { index in
      index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil
    }
    let fixture = base.deletingLastPathComponent().appendingPathComponent(
      "Fixtures/PlaybackFixture.mp4")
    let requestedMedia =
      explicitMedia ?? (FileManager.default.fileExists(atPath: fixture.path) ? fixture.path : nil)
    let sample =
      requestedMedia.map { path in
        model.library.first { $0.url.flatMap(URL.init(string:))?.path == path }
          ?? MediaItem(
            id: "ui-test-fixture", title: "MTV 播放测试", url: URL(fileURLWithPath: path).absoluteString
          )
      }
    if let playable = sample,
      let address = playable.url, let url = URL(string: address)
    {
      model.beginPlayback(url: url, item: playable)
      for _ in 0..<150 {
        if model.elapsed > 2 { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      checks["nativeMP4TimelineAdvanced"] = model.elapsed > 2
      let frame = model.testDecodedFrame()
      checks["nativeMP4DecodedFrame"] = frame != nil
      if let frame,
        let png = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])
      {
        try? png.write(to: output.appendingPathComponent("05-decoded-frame.png"), options: .atomic)
      }
      playbackDiagnostics = [
        "state": model.playbackState, "notice": model.notice ?? "",
        "itemStatus": model.player?.currentItem?.status.rawValue ?? -1,
        "playerTime": model.player?.currentTime().seconds ?? -1,
      ]
      await settle()
      capture(window, to: output.appendingPathComponent("05-playback.png"))
      for _ in 0..<60 {
        if !model.playerControlsVisible { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      checks["playerControlsAutoHide"] = !model.playerControlsVisible
      model.handle(.up)
      checks["playerControlsRemoteReveal"] = model.playerControlsVisible
      model.playerCommand(1)
      checks["pause"] = model.paused
      model.handle(.back)
      checks["firstBackHidesControlsWithoutClosingPlayer"] = model.player != nil && !model.playerControlsVisible
      model.handle(.back)
      checks["playbackClosed"] = model.player == nil
    } else {
      checks["nativeMP4TimelineAdvanced"] = false
    }
    checks.merge(await librarySmoke(model: model, output: output, window: window)) { _, latest in
      latest
    }
    checks.merge(await smbSmoke(model: model, output: output, window: window)) { _, latest in latest
    }
    checks.merge(await metadataSmoke(model: model, output: output, window: window)) { _, latest in
      latest
    }
    checks.merge(await artworkSmoke(output: output)) { _, latest in latest }
    checks.merge(await automaticMetadataSmoke(model: model, output: output, window: window)) {
      _, latest in latest
    }
    checks.merge(await localFolderSmoke(model: model, output: output, window: window)) { _, latest in latest }
    checks.merge(await libraryIndexSmoke(model: model, output: output, window: window)) { _, latest in latest }
    checks.merge(await smbProfilesSmoke(model: model, output: output, window: window)) { _, latest in latest }
    checks.merge(await smbIdentitySmoke(model: model, output: output, window: window)) { _, latest in latest }
    checks.merge(await smbOfflineSmoke(model: model, output: output, window: window)) { _, latest in latest }
    checks.merge(await smbNetworkSmoke(model: model, output: output)) { _, latest in latest }
    checks.merge(await savedSourcesSmoke(model: model, output: output, window: window)) { _, latest in latest }
    checks.merge(await hdrSmoke(model: model, output: output, window: window)) { _, latest in latest }
    checks.merge(await loopbackMediaSmoke()) { _, latest in latest }
    checks.merge(await indexedRangeSmoke(output: output)) { _, latest in latest }
    checks.merge(await remoteHeaderSmoke(model: model, output: output)) { _, latest in latest }
    if CommandLine.arguments.contains("--test-split-http") {
      checks.merge(await splitPlaybackSmoke(model: model, output: output)) { _, latest in latest }
    }
    let liveServices = CommandLine.arguments.contains("--live-services")
    if CommandLine.arguments.contains("--test-vlc") {
      checks["vlcBundledEngine"] = VLCPlaybackEngine.isAvailable
      let fixtureArgument = CommandLine.arguments.firstIndex(of: "--vlc-fixtures").flatMap {
        index in
        index + 1 < CommandLine.arguments.count ? CommandLine.arguments[index + 1] : nil
      }
      if VLCPlaybackEngine.isAvailable, let fixtureArgument {
        checks.merge(
          await automaticPlaybackSmoke(
            model: model, root: URL(fileURLWithPath: fixtureArgument), output: output)
        ) { _, latest in latest }
        model.performSetting(.engine)
        checks["legacyEngineDiagnosticPickerAvailable"] = model.enginePickerVisible
        model.enginePickerIndex = PlaybackEngineChoice.allCases.firstIndex(of: .vlc)!
        model.handle(.select)
        checks["engineChoiceExplicitVLC"] =
          model.preferredEngine == .vlc && !model.enginePickerVisible
        for (name, label) in [
          ("h264-aac.mkv", "mkv"), ("h264-subtitles.mp4", "subtitles"),
          ("h264-two-audio.mp4", "audio"),
        ] {
          let url = URL(fileURLWithPath: fixtureArgument).appendingPathComponent(name)
          let item = MediaItem(
            id: "vlc-test-" + label, title: "VLC 生成片源 · " + label, url: url.absoluteString)
          model.beginPlayback(url: url, item: item)
          for _ in 0..<250 {
            if let stats = model.vlcEngine?.latest,
              stats.elapsed > 2 && stats.decodedVideo > 0 || stats.state == 7
            {
              break
            }
            try? await Task.sleep(for: .milliseconds(100))
          }
          let stats = model.vlcEngine?.latest
          checks["vlc-" + label + "-decoded"] =
            (stats?.elapsed ?? 0) > 2 && (stats?.decodedVideo ?? 0) > 0
          if label == "mkv", CommandLine.arguments.contains("--quit-probe") {
            let index = CommandLine.arguments.firstIndex(of: "--quit-probe-id")
            let identifier =
              index.flatMap {
                $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil
              } ?? ""
            let report: [String: Any] = [
              "kind": "quit-probe-ready", "id": identifier,
              "pid": ProcessInfo.processInfo.processIdentifier, "state": stats?.state ?? -1,
              "elapsed": stats?.elapsed ?? 0, "decodedFrames": stats?.decodedVideo ?? 0,
              "handlerInstalled": ApplicationLifecycle.signalHandlerInstalled,
              "runDirectory": output.path,
            ]
            if let data = try? JSONSerialization.data(
              withJSONObject: report, options: [.prettyPrinted])
            {
              try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
              try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
            }
            return
          }
          moduleDiagnostics["vlc-" + label] = model.playbackState
          if let engine = model.vlcEngine {
            if label == "mkv" {
              checks["vlcEmbeddedVideoDisplayed"] = (stats?.displayedPictures ?? 0) > 0
              let surface = engine.surfaceMetrics
              checks["vlcDrawableAttachedAndSized"] =
                surface["attachedToWindow"] == 1 && (surface["width"] ?? 0) > 0
                && (surface["height"] ?? 0) > 0 && (surface["visibleVideoSubviews"] ?? 0) > 0
              let snapshot = output.appendingPathComponent("11-vlc-decoded.png")
              let taken = await engine.snapshot(to: snapshot)
              checks["vlcSnapshot"] = taken && FileManager.default.fileExists(atPath: snapshot.path)
              model.playerCommand(1)
              try? await Task.sleep(for: .milliseconds(400))
              checks["vlcPause"] = model.vlcEngine?.latest?.state == 4
              model.playerCommand(1)
              await settle()
              capture(window, to: output.appendingPathComponent("12-vlc-player.png"))
            }
            if label == "subtitles" {
              checks["vlcSubtitlesDefaultOnWhenAvailable"] = (stats?.subtitleID ?? -1) >= 0
              model.playerCommand(4)
              for _ in 0..<100 { if !model.playbackTracks.loading { break }; try? await Task.sleep(for: .milliseconds(20)) }
              while model.playbackTracks.selection > 0 { model.handle(.up) }
              model.handle(.select)
              for _ in 0..<100 { if !model.playbackTracks.isPresented { break }; try? await Task.sleep(for: .milliseconds(20)) }
              await settle()
              checks["vlcSubtitlesCanStillBeExplicitlyDisabled"] = model.vlcEngine?.latest?.subtitleID == -1
              _ = await chooseDifferentPlaybackTrack(model: model, kind: .subtitles)
              await settle()
              checks["vlcSubtitleSwitch"] = (model.vlcEngine?.latest?.subtitleID ?? -1) >= 0
            }
            if label == "audio" {
              let oldTime = model.elapsed
              let oldTrack = model.vlcEngine?.latest?.audioID
              _ = await chooseDifferentPlaybackTrack(model: model, kind: .audio)
              await settle()
              checks["vlcAudioSwitchCommand"] =
                model.vlcEngine?.latest?.audioID != oldTrack
                && (model.vlcEngine?.latest?.audioID ?? -1) >= 0
              model.playerCommand(1)
              try? await Task.sleep(for: .milliseconds(400))
              model.playerCommand(2)
              await settle()
              checks["vlcSeekCommand"] = model.elapsed > oldTime + 1
            }
          }
          exitPlaybackWithRemote(model: model)
          checks["vlc-" + label + "-closed"] = !model.playbackPresented
        }
        model.preferredEngine = .system
        model.navigate(.home)
      } else {
        moduleDiagnostics["vlc"] = "缺少通用引擎或生成片源目录"
      }
    }
    checks["bilibiliModuleRegistered"] = model.plugins.contains {
      $0.id == "mtv.bilibili" && $0.manifest.capabilities.contains("browse")
    }
    if let authPlugin = model.plugins.first(where: { $0.manifest.authentication != nil }) {
      model.activePlugin = authPlugin
      model.section = .bilibili
      model.rebuildFocus(reset: true)
      model.focus.select(row: 1, column: 0)
      model.handle(.right)
      checks["accountActionRemoteReachable"] = model.focus.column == 1
      model.login.presentFixture(authPlugin)
      checks["loginFixtureRendered"] = model.login.isPresented && model.login.qrImage != nil
      checks["qrPayloadRoundtrip"] =
        model.login.qrImage.flatMap(decodeQR) == "https://example.invalid/mtv-login-ui-fixture"
      await settle()
      capture(window, to: output.appendingPathComponent("10-login-fixture.png"))
      model.handle(.back)
      checks["loginRemoteBack"] = !model.login.isPresented
      model.login.presentFixture(authPlugin)
      model.handle(.select)
      checks["loginRemoteCloseButton"] = !model.login.isPresented
      if CommandLine.arguments.contains("--test-keychain") {
        var fixtureManifest = authPlugin.manifest
        fixtureManifest.id = "test.ui-logout." + UUID().uuidString.lowercased()
        fixtureManifest.name = "退出登录回归测试"
        let fixturePlugin = PluginRecord(manifest: fixtureManifest, directory: authPlugin.directory)
        let fixtureID = fixturePlugin.id
        do {
          let session = PluginSession(
            pluginID: fixtureID, domains: fixtureManifest.authentication?.sessionDomains ?? [],
            cookie: "SESSDATA=MTV_UI_TEST_ONLY", expiresAt: Date().timeIntervalSince1970 + 600)
          try await Task.detached { try PluginSessionStore().save(session) }.value
          model.login.refresh(fixturePlugin)
          for _ in 0..<100 {
            if model.login.savedSessions.contains(fixtureID) { break }
            try? await Task.sleep(for: .milliseconds(100))
          }
          if model.login.savedSessions.contains(fixtureID) {
            // Cached-session UI only: do not generate a live login for a fake fixture ID.
            model.login.present(fixturePlugin)
            model.handle(.right)
            model.handle(.right)
            model.handle(.select)
            for _ in 0..<100 {
              if model.login.state == "signedOut" || model.login.state == "failed" { break }
              try? await Task.sleep(for: .milliseconds(100))
            }
            let removed = try await Task.detached {
              try PluginSessionStore().load(pluginID: fixtureID) == nil
            }.value
            checks["loginUIOwnRecordSignOut"] =
              removed && model.login.state == "signedOut"
              && !model.login.savedSessions.contains(fixtureID)
          } else {
            checks["loginUIOwnRecordSignOut"] = false
          }
        } catch {
          checks["loginUIOwnRecordSignOut"] = false
          moduleDiagnostics["logoutFixture"] = error.localizedDescription
        }
        try? await Task.detached { try PluginSessionStore().remove(pluginID: fixtureID) }.value
        model.login.close()
      }
      model.navigate(.home)
    }
    if CommandLine.arguments.contains("--test-login-qr"),
      let plugin = model.plugins.first(where: { $0.id == "mtv.bilibili" })
    {
      model.showLogin(plugin)
      for _ in 0..<260 {
        if model.login.state != "loading" { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      checks["liveLoginQRGenerated"] = model.login.qrImage != nil && model.login.state == "waiting"
      // Never save a real QR image, login URL, token, or cookie to the report.
      moduleDiagnostics["liveLoginQR"] =
        model.login.state == "waiting" ? "已生成，未扫码；令牌未记录" : model.login.message
      model.login.close()
    }
    if liveServices {
      model.navigate(.bilibili)
      for _ in 0..<270 {
        if !model.loading { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      checks["bilibiliPageLoaded"] = !model.online.isEmpty
      let baselinePlaybackItem = model.online.first
      checks["pluginSourceProvenance"] =
        !model.online.isEmpty && model.online.allSatisfy { $0.source == model.activePlugin?.id }
      if model.notice == nil {
        await settle()
        capture(window, to: output.appendingPathComponent("06-bilibili.png"))
      }
      model.notice = nil
      if model.moduleNextPage != nil {
        let oldCount = model.online.count
        model.focus.select(row: 2 + model.mediaRows.count, column: 0)
        model.handle(.select)
        for _ in 0..<270 {
          if !model.loading { break }
          try? await Task.sleep(for: .milliseconds(100))
        }
        checks["modulePaginationAppends"] =
          model.online.count > oldCount && Set(model.online.map(\.id)).count == model.online.count
        model.notice = nil
      }
      if let plugin = model.activePlugin, plugin.manifest.capabilities.contains("search") {
        model.showKeyboard()
        model.search = "猫"
        model.pressKey("完成")
        for _ in 0..<270 {
          if !model.loading { break }
          try? await Task.sleep(for: .milliseconds(100))
        }
        checks["bilibiliSearch"] = !model.online.isEmpty && model.notice == nil
        moduleDiagnostics["bilibiliSearch"] = model.moduleLoadFailure?.message ?? model.notice ?? "返回 \(model.online.count) 项"
        if model.notice == nil {
          await settle()
          capture(window, to: output.appendingPathComponent("07-search-results.png"))
        }
        model.notice = nil
      }
      if let first = baselinePlaybackItem {
        model.stopPlayback()
        model.play(first)
        for _ in 0..<270 {
          if !model.loading { break }
          try? await Task.sleep(for: .milliseconds(100))
        }
        for _ in 0..<150 {
          if (model.player != nil && model.playbackTitle == first.title && model.elapsed > 2) || model.player?.currentItem?.status == .failed
            || model.notice != nil
          {
            break
          }
          try? await Task.sleep(for: .milliseconds(100))
        }
        checks["bilibiliNativePlayback"] = model.player?.currentItem?.status == .readyToPlay
          && model.playbackTitle == first.title && model.elapsed > 2
        checks["bilibiliNativeFrameDecoded"] = model.player != nil && model.playbackTitle == first.title
          && model.testDecodedFrame() != nil
        playbackDiagnostics["bilibiliState"] = model.notice ?? model.playbackState
        model.stopPlayback()
        model.notice = nil
      } else {
        checks["bilibiliNativePlayback"] = false
        checks["bilibiliNativeFrameDecoded"] = false
      }
    }
    if CommandLine.arguments.contains("--developer-mode"),
      let example = model.plugins.first(where: { $0.id == "mtv.example" })
    {
      model.openModule(example)
      model.navigate(.home)
      await settle()
      checks["moduleCancellationKeepsNavigation"] =
        model.section == .home && !model.loading && model.detail == nil
      model.openModule(example)
      for _ in 0..<270 {
        if !model.loading { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      checks["genericPluginPage"] =
        model.online.first?.title == "Hello, MacTV" && model.online.first?.source == example.id
      await settle()
      capture(window, to: output.appendingPathComponent("08-example-module.png"))
      if model.moduleNextPage != nil {
        model.focus.select(row: model.mediaFocusOffset, column: 0)
        model.handle(.down)
      }
      for _ in 0..<100 {
        if !model.loading { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      checks["genericPluginPagination"] =
        model.online.count == 3 && Set(model.online.map(\.id)).count == 3 && model.moduleNextPage == nil
      let parentIDs = model.online.map(\.id)
      model.focus.select(row: 2, column: 2)
      model.handle(.select)
      for _ in 0..<100 {
        if !model.loading { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      checks["moduleFolderRemoteEnter"] =
        model.modulePath.count == 1 && model.online.first?.id == "folder-two" && model.detail == nil
      await settle()
      capture(window, to: output.appendingPathComponent("13-plugin-folder.png"))
      model.focus.select(row: 2, column: 0)
      model.handle(.select)
      for _ in 0..<100 {
        if !model.loading { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      checks["moduleNestedFolderRemoteEnter"] =
        model.modulePath.count == 2 && model.online.first?.id == "nested-video"
      model.handle(.back)
      checks["moduleFolderBackRestoresParent"] =
        model.modulePath.count == 1 && model.online.first?.id == "folder-two"
        && model.focus.row == 2
      model.handle(.back)
      checks["moduleFolderBackRestoresRootPageAndFocus"] =
        model.modulePath.isEmpty && model.online.map(\.id) == parentIDs && model.focus.row == 2
        && model.focus.column == 2 && model.moduleNextPage == nil
      model.handle(.select)
      model.handle(.back)
      await settle()
      checks["moduleFolderCancellationPreservesParent"] =
        model.modulePath.isEmpty && model.online.map(\.id) == parentIDs && !model.loading
      model.showKeyboard()
      model.search = "Search"
      model.pressKey("完成")
      for _ in 0..<100 {
        if !model.loading { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      checks["genericPluginSearch"] =
        model.online.count == 1 && model.online.first?.id == "search"
        && model.online.first?.source == example.id
      await settle()
      capture(window, to: output.appendingPathComponent("09-example-search.png"))
      model.notice = nil
    } else {
      checks["developerModulesHidden"] = model.plugins.allSatisfy {
        $0.manifest.presentation?.developerOnly != true
      }
    }
    model.navigate(.extensions)
    // Exercise the real module route as a guest, without loading a user's stored
    // cloud account or issuing authenticated requests in this offline regression.
    model.moduleSessionAccess = .guest
    let quarkIndex = model.plugins.firstIndex { $0.id == "mtv.quark" } ?? 0
    model.focus.select(row: 1, column: quarkIndex)
    model.handle(.select)
    for _ in 0..<100 {
      if !model.loading { break }
      try? await Task.sleep(for: .milliseconds(100))
    }
    checks["quarkGuestAccountGate"] =
      model.activePlugin?.id == "mtv.quark" && model.moduleNeedsLogin && model.online.isEmpty
      && model.notice == nil
    checks["quarkPreviewAvailabilityDeclared"] =
      model.activePlugin?.manifest.presentation?.availability == "preview"
    await settle()
    capture(window, to: output.appendingPathComponent("14-quark-guest.png"))
    model.handle(.back)
    model.moduleSessionAccess = .stored
    model.navigate(.home)
    model.focus.select(row: 0, column: 0)
    model.handle(.up)
    model.handle(.left)
    checks["focusBoundary"] = model.focus.row == 0 && model.focus.column == 0
    let report: [String: Any] = [
      "kind": "ui-smoke", "checks": checks, "passed": checks.values.allSatisfy { $0 },
      "pid": ProcessInfo.processInfo.processIdentifier,
      "runDirectory": output.path,
      "initialSourceScope": CommandLine.arguments.contains("--owned-regression") ? "owned-fixtures" : "selected-source",
      "selectedSourceInitializationRequested": !CommandLine.arguments.contains("--owned-regression"),
      "liveServices": liveServices, "tvLayout": CommandLine.arguments.contains("--tv-layout"),
      "metadataLiveRequested": CommandLine.arguments.contains("--live-metadata"),
      "tmdbRealCredentialVerified": false,
      "liveLoginQRRequested": CommandLine.arguments.contains("--test-login-qr"),
      "realAccountAuthorizationVerified": false,
      "keychainTestRequested": CommandLine.arguments.contains("--test-keychain"),
      "smbFixtureRequested": CommandLine.arguments.contains("--smb-fixture-url"),
      "smbNetworkAccessVerified": checks["smbActualVideoTimelineAndDecode"] == true,
      "smbIdentityUsesGeneratedLocalFixtures": true,
      "vlcTestRequested": CommandLine.arguments.contains("--test-vlc"),
      "screenCompositorVerified": false,
      "nativeWindowKeyRouteVerified": checks["localFolderNativeWindowKeyRoute"] == true,
      "terminationSignalHandlerInstalled": ApplicationLifecycle.signalHandlerInstalled,
      "libraryCount": model.library.count, "playbackDiagnostics": playbackDiagnostics,
      "libraryRootCount": model.libraryCatalog.root.count,
      "librarySeriesCount": model.libraryCatalog.root.filter { $0.kind == .series }.count,
      "moduleDiagnostics": moduleDiagnostics,
      "playbackSample": requestedMedia.map { URL(fileURLWithPath: $0).lastPathComponent }
        ?? "missing generated fixture", "physicalRemoteTested": false, "hdrOutputTested": false,
    ]
    if let data = try? JSONSerialization.data(
      withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
    {
      try? data.write(to: output.appendingPathComponent("ui-smoke.json"), options: .atomic)
      try? data.write(to: base.appendingPathComponent("ui-smoke.json"), options: .atomic)
    }
    await settle()
    capture(window, to: output.appendingPathComponent("04-final-home.png"))
  }
  static func librarySmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    let saved = model.captureLibrarySource()
    defer {
      model.stopPlayback()
      model.detail = nil
      model.navigate(.home)
      model.restoreLibrarySource(saved)
    }
    var checks: [String: Bool] = [:]
    do {
      let root = output.appendingPathComponent("StandaloneLibrary", isDirectory: true)
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/MTV/Fixtures/PlaybackFixture.mp4")
      for relative in [
        "Movies/Test.Movie.2024.1080p.mp4",
        "TV/Example Show/Season 1/Example.Show.S01E02.Second.mp4",
        "TV/Example Show/Season 1/Example.Show.S01E01.First.mp4",
        "TV/Example Show/Season 1/Example.Show.S01E03.Third.mp4",
        "TV/Example Show/Season 1/Example.Show.S01E04.Fourth.mp4",
        "TV/Example Show/Season 1/Example.Show.S01E05.Fifth.mp4",
        "TV/Example Show/Season 1/Example.Show.S01E06.Sixth.mp4",
        "TV/Example Show/Season 2/Example.Show.S02E01.Return.mp4",
      ] {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: file)
      }
      let files = try await Task.detached { try LibraryScanner.scan(root: root) }.value
      model.applyLibraryItems(files)
      model.navigate(.library)
      checks["standaloneLibraryWithoutNFO"] =
        files.count == 8 && model.libraryCatalog.root.count == 2
        && files.first { $0.title == "Test Movie" }?.localMetadata?.year == 2024
      let index = model.visibleItems.firstIndex { $0.kind == .series } ?? 0
      model.focus.select(row: 2 + index / 6, column: index % 6)
      model.handle(.select)
      checks["librarySeriesRemoteEnter"] =
        model.libraryPath.count == 1 && model.visibleItems.count == 7
        && model.visibleItems.allSatisfy { !$0.isLibraryCollection }
      await settle()
      capture(window, to: output.appendingPathComponent("16-series-seasons.png"))
      model.focus.select(row: 2, column: 0)
      checks["librarySeasonRemoteEnterAndOrder"] =
        model.libraryPath.count == 1
        && model.visibleItems.map { $0.localMetadata?.episode } == [1, 2, 3, 4, 5, 6, 1]
      model.focus.select(row: 2, column: 0)
      model.handle(.down)
      model.handle(.right)
      model.handle(.select)
      for _ in 0..<100 {
        if model.playbackPresented || model.notice != nil { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      checks["libraryEpisodeDetail"] =
        model.detail == nil && model.playingItem?.title == "Sixth" && model.playingItem?.localMetadata?.episode == 6
      var decoded = false
      for _ in 0..<120 {
        if let frame = model.testDecodedFrame() {
          decoded = true
          if let png = NSBitmapImageRep(cgImage: frame).representation(using: .png, properties: [:])
          {
            try? png.write(
              to: output.appendingPathComponent("17-standalone-episode-decoded.png"),
              options: .atomic)
          }
        }
        if model.elapsed > 1 && decoded { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      checks["standaloneEpisodeActualPlayback"] = model.elapsed > 1 && decoded
      exitPlaybackWithRemote(model: model)
      checks["libraryBackRestoresSeasonFocus"] =
        model.libraryPath.count == 1 && model.focus.row == 3 && model.focus.column == 1
      model.handle(.back)
      checks["libraryBackRestoresRootFocus"] =
        model.libraryPath.isEmpty && model.focus.row == 2 + index / 6
        && model.focus.column == index % 6
    } catch { checks["standaloneLibraryFixture"] = false }
    return checks
  }
  static func smbSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    let source = model.captureLibrarySource()
    var checks: [String: Bool] = [:]
    await openSettingWithRemote(.nas, model: model)
    let search = model.search
    checks["smbSettingsRemoteEntry"] = model.smb.isPresented
    model.smb.guest = false
    model.smb.selection = 0
    model.handle(.select)
    checks["smbAddressOnScreenKeyboard"] =
      model.keyboardVisible && model.textEntryTarget == .smbAddress
    model.pressKey("清空")
    model.handle(.text("smb://fixture.invalid/Movies"))
    model.pressKey("完成")
    checks["smbAddressDraftCommitted"] = model.smb.address == "smb://fixture.invalid/Movies"
    model.smb.selection = 3
    model.handle(.select)
    model.pressKey("清空")
    model.pressKey("大小写")
    for key in ["S", "M", "B"] { model.pressKey(key) }
    model.pressKey("大小写")
    for key in "-test-only" { model.pressKey(String(key)) }
    model.pressKey("符号")
    model.handle(.select)
    model.handle(.down)
    model.handle(.down)
    for _ in 0..<9 { model.handle(.right) }
    model.handle(.select)
    checks["smbPasswordOnScreenSymbols"] = model.inputText == "SMB-test-only!?"
    checks["smbPasswordMaskedAndIsolated"] =
      model.keyboardSecret && model.keyboardDisplayText == String(repeating: "•", count: 15)
      && model.search == search
    await settle()
    capture(window, to: output.appendingPathComponent("18-smb-password.png"))
    model.keyboardFocus.select(
      row: model.keyboardRows.count - 1, column: model.keyboardRows.last!.count - 1)
    model.handle(.select)
    checks["smbPasswordRemoteDone"] =
      !model.keyboardVisible && model.smb.password == "SMB-test-only!?"
    model.smb.selection = 1
    model.handle(.select)
    checks["smbGuestToggleDropsPassword"] = model.smb.guest && model.smb.password.isEmpty
    model.handle(.back)
    checks["smbRemoteCancel"] =
      !model.smb.isPresented && !model.keyboardVisible && model.search == search
    checks["smbCancelReturnsToSourcesParent"] = model.savedSources.isPresented
    model.handle(.back)
    checks["smbSourcesSecondBackReturnsToSettings"] = !model.savedSources.isPresented && model.section == .settings
    if let index = CommandLine.arguments.firstIndex(of: "--smb-fixture-url"),
      index + 1 < CommandLine.arguments.count
    {
      let address = CommandLine.arguments[index + 1]
      if let location = try? SMBLocation(address), location.shareURL.host == "127.0.0.1",
        location.shareURL.path == "/MTVFixture"
      {
        model.smb.present()
        model.smb.address = address
        model.smb.guest = true
        model.smb.connect()
        for _ in 0..<300 {
          if model.smb.phase != "connecting" && model.smb.phase != "loading" { break }
          try? await Task.sleep(for: .milliseconds(100))
        }
        checks["smbNativeReadOnlyDirectoryBrowse"] = model.smb.readOnlyConnected
        await settle()
        capture(window, to: output.appendingPathComponent("19-smb-browser.png"))
        if model.smb.readOnlyConnected {
          model.smb.selection = 0
          model.handle(.select)
          for _ in 0..<150 {
            if !model.loading { break }
            try? await Task.sleep(for: .milliseconds(100))
          }
          checks["smbSourceScan"] =
            model.library.count == 1 && model.library.first?.title == "SMB Test Movie"
          model.focus.select(row: 2, column: 0)
          model.handle(.select)
          model.handle(.select)
          var decoded = false
          for _ in 0..<150 {
            if let frame = model.testDecodedFrame() {
              decoded = true
              if let png = NSBitmapImageRep(cgImage: frame).representation(
                using: .png, properties: [:])
              {
                try? png.write(
                  to: output.appendingPathComponent("20-smb-decoded.png"), options: .atomic)
              }
            }
            if model.elapsed > 1 && decoded { break }
            try? await Task.sleep(for: .milliseconds(100))
          }
          checks["smbActualVideoTimelineAndDecode"] = model.elapsed > 1 && decoded
        }
      } else {
        checks["smbFixtureScopeRejected"] = false
      }
    }
    if model.keyboardVisible { model.handle(.back) }
    model.stopPlayback()
    model.detail = nil
    model.smb.close()
    model.restoreLibrarySource(source)
    model.navigate(.home)
    await settle()
    await model.releaseInactiveSMBShares()
    return checks
  }
  static func automaticPlaybackSmoke(model: AppModel, root: URL, output: URL) async -> [String:
    Bool]
  {
    let saved = model.preferredEngine
    defer {
      model.stopPlayback()
      model.preferredEngine = saved
    }
    var checks: [String: Bool] = [:]
    model.preferredEngine = .automatic
    checks["automaticPlaybackNeedsNoEngineSetting"] = !TVSetting.groups.flatMap { $0 }.contains(.engine)
    for (name, engine) in [
      ("h264-aac.mp4", PlaybackEngineChoice.system), ("h264-aac.mkv", .mpv),
      ("hevc-aac.mp4", .system), ("h264-eac3.mp4", .system),
    ] {
      let url = root.appendingPathComponent(name)
      model.beginPlayback(
        url: url,
        item: MediaItem(id: "auto-fixture-" + name, title: "自动选择测试", url: url.absoluteString))
      var decoded = false
      for _ in 0..<200 {
        if engine == .system {
          decoded = decoded || model.testDecodedFrame() != nil
        } else {
          decoded = decoded || (model.mpvEngine?.latest?.frames ?? 0) > 0
        }
        if model.elapsed > 1 && decoded || model.notice != nil { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      checks["auto-" + name + "-engine"] =
        engine == .system
        ? (model.player != nil && model.vlcEngine == nil)
        : (model.player == nil && model.mpvEngine != nil)
      checks["auto-" + name + "-decoded"] = model.elapsed > 1 && decoded && model.notice == nil
      model.stopPlayback()
    }
    let cancelURL = root.appendingPathComponent("h264-aac.mp4")
    model.beginPlayback(
      url: cancelURL,
      item: MediaItem(id: "auto-cancel", title: "取消测试", url: cancelURL.absoluteString))
    model.handle(.back)
    await settle()
    checks["automaticCancelDoesNotStartLater"] =
      !model.preparingPlayback && model.player == nil && model.vlcEngine == nil && model.mpvEngine == nil
    let empty = output.appendingPathComponent("empty-preflight.mp4")
    do {
      try Data().write(to: empty)
      model.beginPlayback(
        url: empty, item: MediaItem(id: "auto-empty", title: "空文件测试", url: empty.absoluteString))
      for _ in 0..<100 {
        if !model.preparingPlayback { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      checks["automaticEmptyFileDoesNotChangeEngineOrPlay"] =
        model.notice?.contains("文件为空") == true && model.player == nil && model.vlcEngine == nil
        && model.preferredEngine == .automatic
      model.handle(.back)
    } catch { checks["automaticEmptyFileDoesNotChangeEngineOrPlay"] = false }
    return checks
  }
  struct FixtureMetadata: MetadataSearching {
    func search(query: String, kind: MetadataKind, provider: MetadataProvider, token: String?)
      async throws -> [MetadataCandidate]
    {
      [
        MetadataCandidate(
          provider: provider, externalID: 101, kind: kind,
          title: kind == .series ? "Fixture matched series" : "Fixture matched movie", year: 2024,
          overview: "Only generated test media is updated"),
        MetadataCandidate(
          provider: provider, externalID: 102, kind: kind, title: "Other version", year: 1980),
      ]
    }
  }
  static func metadataSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool]
  {
    let source = model.captureLibrarySource()
    let store = model.metadataStore
    let client = model.metadata.client
    let tokenStore = model.metadata.tokenStore
    let token = model.metadata.tmdbToken
    defer {
      if model.keyboardVisible { model.handle(.back) }
      model.metadata.close()
      model.metadataStore = store
      model.metadata.client = client
      model.metadata.tokenStore = tokenStore
      model.metadata.tmdbToken = token
      model.restoreLibrarySource(source)
      model.detail = nil
      model.navigate(.home)
    }
    var checks: [String: Bool] = [:]
    let temporaryTokenStore = MetadataTokenStore(
      service: "local.mtv.preview.metadata-token.test." + UUID().uuidString)
    model.metadata.tokenStore = temporaryTokenStore
    model.metadata.tmdbToken = nil
    model.metadata.client = FixtureMetadata()
    model.metadataStore = MetadataStore(
      file: output.appendingPathComponent("metadata/matches.json"))
    do {
      let files = try LibraryScanner.scan(root: output.appendingPathComponent("StandaloneLibrary"))
      model.applyLibraryItems(files)
      model.navigate(.library)
      let movie = model.visibleItems.firstIndex { !$0.isLibraryCollection } ?? 0
      model.focus.select(row: 2 + movie / 6, column: movie % 6)
      model.selectContent(model.visibleItems[movie])
      let originalID = model.detail?.id
      let originalURL = model.detail?.url
      if let detail = model.detail, let index = model.detailControls(for: detail).firstIndex(of: .metadata) {
        for _ in 0..<index { model.handle(.right) }
      }
      model.handle(.select)
      for _ in 0..<100 {
        if !model.metadata.loading { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      checks["metadataDetailRemoteEntry"] =
        model.metadata.isPresented && model.metadata.candidates.count == 2
      model.handle(.down)
      model.handle(.down)
      checks["metadataResultsRemoteNavigation"] = model.metadata.selection == 5
      model.handle(.up)
      model.handle(.right)
      model.handle(.select)
      model.handle(.text(String(repeating: "TOKEN_FIXTURE_NOT_SAVED", count: 12)))
      checks["metadataTokenMasked"] =
        model.keyboardSecret && !model.keyboardDisplayText.contains("TOKEN")
      model.handle(.back)
      model.handle(.down)
      model.handle(.select)
      checks["metadataMovieAppliedWithoutChangingURL"] =
        model.detail?.title == "Fixture matched movie" && model.detail?.id == originalID
        && model.detail?.url == originalURL
      let fresh = try MetadataStore(file: model.metadataStore.file).load()
      checks["metadataMatchPersisted"] = fresh[originalID ?? ""]?.candidate.externalID == 101
      model.applyLibraryItems(files)
      checks["metadataRescanKeepsMatch"] =
        model.library.first { $0.id == originalID }?.title == "Fixture matched movie"
      if let detail = model.detail { model.presentMetadata(for: detail) }
      model.metadata.selection = 4
      model.handle(.select)
      let restored = try model.metadataStore.load()
      checks["metadataRestoreOriginal"] = model.detail?.title == "Test Movie" && restored.isEmpty
      model.detail = nil
      model.navigate(.library)
      let seriesIndex = model.visibleItems.firstIndex { $0.kind == .series } ?? 0
      let seriesID = model.visibleItems[seriesIndex].id
      model.focus.select(row: 2 + seriesIndex / 6, column: seriesIndex % 6)
      model.handle(.select)
      model.focus.select(row: 1, column: 2)
      model.handle(.select)
      for _ in 0..<100 {
        if !model.metadata.loading { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      checks["metadataSeriesHeaderRemoteEntry"] =
        model.metadata.isPresented && model.metadata.kind == .series
      await settle()
      capture(window, to: output.appendingPathComponent("21-metadata-picker.png"))
      model.metadata.selection = 5
      model.handle(.select)
      checks["metadataSeriesIdentityAndPathPreserved"] =
        model.libraryPath.first?.id == seriesID
        && model.libraryPath.first?.title == "Fixture matched series"
      model.handle(.back)
      checks["metadataSeriesBackStillWorks"] =
        model.libraryPath.isEmpty && model.section == .library
      if CommandLine.arguments.contains("--live-metadata"),
        let series = model.libraryCatalog.root.first(where: { $0.kind == .series })
      {
        model.metadata.client = client
        model.metadata.present(series, search: false)
        model.metadata.query = "Family Guy"
        model.metadata.search()
        for _ in 0..<300 {
          if !model.metadata.loading { break }
          try? await Task.sleep(for: .milliseconds(50))
        }
        checks["metadataLiveTVmazeResults"] = model.metadata.candidates.contains {
          $0.externalID == 84 && $0.title == "Family Guy"
        }
        if let candidate = model.metadata.candidates.first(where: { $0.externalID == 84 }),
          let address = candidate.poster, let url = URL(string: address)
        {
          let cacheRoot = output.appendingPathComponent("live-artwork-cache")
          let warm = ArtworkCache(disk: ArtworkDiskStore(root: cacheRoot))
          async let first = warm.image(for: url)
          async let second = warm.image(for: url)
          let images = await (first, second)
          checks["metadataLiveArtworkDecoded"] = images.0 != nil && images.1 != nil
          checks["artworkConcurrentNetworkRequestCoalesced"] = await warm.networkRequests() == 1
          let cold = ArtworkCache(disk: ArtworkDiskStore(root: cacheRoot), allowsNetwork: false)
          checks["metadataArtworkColdOfflineDecoded"] = await cold.image(for: url) != nil
          checks["metadataArtworkColdMakesNoRequest"] = await cold.networkRequests() == 0
        }
        if let index = model.metadata.candidates.firstIndex(where: { $0.externalID == 84 }) {
          model.metadata.selection = index + 5
        }
        await settle()
        capture(window, to: output.appendingPathComponent("22-metadata-live.png"))
        if let index = model.metadata.candidates.firstIndex(where: { $0.externalID == 84 }) {
          model.metadata.selection = index + 5
          model.handle(.select)
          checks["metadataLiveMatchApplied"] =
            model.libraryCatalog.root.first { $0.id == seriesID }?.title == "Family Guy"
        }
      }
      if CommandLine.arguments.contains("--test-keychain") {
        let passed = try await Task.detached {
          defer { try? temporaryTokenStore.remove() }
          try temporaryTokenStore.save("MTV_TOKEN_TEST_ONLY_1234567890")
          return try temporaryTokenStore.load() == "MTV_TOKEN_TEST_ONLY_1234567890"
            && temporaryTokenStore.isConfigured
        }.value
        checks["metadataOwnTokenKeychainRoundtrip"] = passed && !temporaryTokenStore.isConfigured
      }
    } catch { checks["metadataFixtureFlow"] = false }
    return checks
  }
  static func artworkSmoke(output: URL) async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    do {
      let root = output.appendingPathComponent("offline-artwork-cache")
      let url = URL(string: "https://cache-fixture.invalid/poster.png")!
      let data = try Data(
        contentsOf: output.appendingPathComponent("17-standalone-episode-decoded.png"))
      try await ArtworkDiskStore(root: root).write(data, for: url)
      let cold = ArtworkCache(disk: ArtworkDiskStore(root: root), allowsNetwork: false)
      checks["artworkColdOfflineDecoded"] = await cold.image(for: url) != nil
      checks["artworkOfflineMakesNoRequest"] = await cold.networkRequests() == 0
      let corrupt = URL(string: "https://cache-fixture.invalid/corrupt.png")!
      try await ArtworkDiskStore(root: root).write(Data("broken image".utf8), for: corrupt)
      checks["artworkCorruptCacheRejected"] = await cold.image(for: corrupt) == nil
      checks["artworkCorruptCacheRemoved"] =
        try await ArtworkDiskStore(root: root).read(corrupt) == nil
    } catch { checks["artworkFixtureStore"] = false }
    return checks
  }
  static func settle() async { try? await Task.sleep(for: .milliseconds(800)) }
  nonisolated static func sessionPersistence(scope: String, write: Bool) -> (
    checks: [String: Bool], error: String?
  ) {
    guard UUID(uuidString: scope) != nil else { return ([:], "测试 scope 必须是 UUID") }
    let id = "test.persistence." + scope.lowercased()
    let store = PluginSessionStore(service: "local.mtv.preview.tests.persistence." + scope)
    do {
      if write {
        let value = PluginSession(
          pluginID: id, domains: ["api.example.test"], cookie: "sid=MTV_PERSISTENCE_TEST_ONLY",
          expiresAt: Date().timeIntervalSince1970 + 600)
        try store.save(value)
        return (["storedOwnPersistenceFixture": store.isConfigured(pluginID: id)], nil)
      }
      let enabled = store.isConfigured(pluginID: id)
      let value = try store.load(pluginID: id)
      let correct = value?.cookie == "sid=MTV_PERSISTENCE_TEST_ONLY" && value?.pluginID == id
      try store.remove(pluginID: id)
      return (
        [
          "accountModeSurvivedRelaunch": enabled, "keychainValueSurvivedRelaunch": correct,
          "ownPersistenceFixtureRemoved": !store.isConfigured(pluginID: id),
        ], nil
      )
    } catch { return ([:], error.localizedDescription) }
  }
  nonisolated static func keychainRoundtrip() -> (checks: [String: Bool], error: String?) {
    let id = "test." + UUID().uuidString.lowercased()
    let store = PluginSessionStore(service: "local.mtv.preview.tests." + UUID().uuidString)
    var created = false
    defer { if created { try? store.remove(pluginID: id) } }
    do {
      var checks: [String: Bool] = [:]
      checks["freshGuestDoesNotReadKeychain"] =
        try store.load(pluginID: id) == nil && !store.isConfigured(pluginID: id)
      let a = PluginSession(pluginID: id, domains: ["api.example.test"], cookie: "sid=TEST_ONLY_A")
      try store.save(a)
      created = true
      checks["savedModeAndValue"] =
        try store.isConfigured(pluginID: id) && store.load(pluginID: id)?.cookie == a.cookie
      let b = PluginSession(pluginID: id, domains: ["api.example.test"], cookie: "sid=TEST_ONLY_B")
      try store.save(b)
      checks["update"] = try store.load(pluginID: id)?.cookie == b.cookie
      checks["otherModule"] = try store.load(pluginID: "other." + id) == nil
      try store.remove(pluginID: id)
      created = false
      checks["removedModeAndValue"] =
        try !store.isConfigured(pluginID: id) && store.load(pluginID: id) == nil
      return (checks, nil)
    } catch { return ([:], error.localizedDescription) }
  }
  static func decodeQR(_ image: NSImage) -> String? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
      return nil
    }
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    do {
      try VNImageRequestHandler(cgImage: cgImage).perform([request])
      return request.results?.first?.payloadStringValue
    } catch { return nil }
  }
  static func capture(_ window: NSWindow, to url: URL) {
    guard let view = window.contentView,
      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
    else { return }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    if let data = bitmap.representation(using: .png, properties: [:]) {
      try? data.write(to: url, options: .atomic)
    }
  }
}

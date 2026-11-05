import AVFoundation
import AppKit
import MTVCore

extension UISmoke {
  static func smbIdentitySmoke(model: AppModel, output: URL, window: NSWindow) async -> [String:
    Bool]
  {
    let source = model.captureLibrarySource()
    let matches = model.metadataStore
    let engine = model.preferredEngine
    defer {
      model.stopPlayback()
      model.metadataStore = matches
      model.preferredEngine = engine
      model.detail = nil
      model.notice = nil
      model.restoreLibrarySource(source)
      model.navigate(.home)
    }
    var checks: [String: Bool] = [:]
    do {
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/MTV/Fixtures/ResumeFixture45.mp4")
      let firstRoot = output.appendingPathComponent("IdentityMountA")
      let secondRoot = output.appendingPathComponent("IdentityMountB")
      for root in [firstRoot, secondRoot] {
        for path in [
          "Movies/Stable.Movie.2024.mp4", "TV/Example Show/Season 1/Example.Show.S01E01.mp4",
        ] {
          let file = root.appendingPathComponent(path)
          try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
          try FileManager.default.linkItem(at: fixture, to: file)
        }
      }
      let profile = try SMBProfile(
        address: "fixture.invalid/Movies", username: "", guest: true, rememberPassword: false)
      let first = try LibraryScanner.scanResult(root: firstRoot).withSMBIdentity(
        profile: profile, mount: firstRoot
      ).items
      let second = try LibraryScanner.scanResult(root: secondRoot).withSMBIdentity(
        profile: profile, mount: secondRoot
      ).items
      checks["smbIdentityStableAcrossGeneratedMountPaths"] =
        first.map(\.id) == second.map(\.id)
        && first.map(\.url) != second.map(\.url)
      checks["smbSeriesIdentityStableAcrossGeneratedMountPaths"] =
        LibraryCatalog.build(first).root.first(where: { $0.kind == .series })?.id
        == LibraryCatalog.build(second).root.first(where: { $0.kind == .series })?.id
      model.metadataStore = MetadataStore(
        file: output.appendingPathComponent("identity-matches/matches.json"))
      model.applyLibraryItems(first)
      guard let movieA = model.library.first(where: { $0.localMetadata?.episode == nil }),
        let rawMovieB = second.first(where: { $0.localMetadata?.episode == nil }),
        let series = model.libraryCatalog.root.first(where: { $0.kind == .series })
      else {
        throw MTVError.message("身份测试库缺少电影或系列")
      }
      try model.applyMetadata(
        item: movieA,
        candidate: MetadataCandidate(
          provider: .tmdb, externalID: 901,
          kind: .movie, title: "Stable matched movie", year: 2024))
      try model.applyMetadata(
        item: series,
        candidate: MetadataCandidate(
          provider: .tvmaze, externalID: 902,
          kind: .series, title: "Stable matched series"))
      model.preferredEngine = .system
      model.notice = nil
      guard let playedA = model.library.first(where: { $0.id == movieA.id }) else {
        throw MTVError.message("缺少初次播放条目")
      }
      model.play(playedA)
      for _ in 0..<200 {
        if model.duration > 40 && model.elapsed > 0 { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      guard let player = model.player, model.duration > 40 else {
        throw MTVError.message("长片源未进入系统播放")
      }
      await player.seek(
        to: CMTime(seconds: 8, preferredTimescale: 600), toleranceBefore: .zero,
        toleranceAfter: .zero)
      for _ in 0..<80 {
        if model.elapsed >= 8 { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      model.stopPlayback()
      let saved = model.resumeStore.position(for: movieA.id)
      checks["smbIdentityActualPlaybackPositionSaved"] = saved >= 7.9 && saved < 12
      model.applyLibraryItems(second)
      checks["smbRemountKeepsMovieAndSeriesMatches"] =
        model.library.contains { $0.title == "Stable matched movie" }
        && model.libraryCatalog.root.contains { $0.title == "Stable matched series" }
      checks["smbRemountUsesCurrentFileURL"] =
        model.library.first { $0.id == movieA.id }?.url == rawMovieB.url
      guard let playedB = model.library.first(where: { $0.id == movieA.id }) else {
        throw MTVError.message("缺少再次播放条目")
      }
      let systemStarted = ProcessInfo.processInfo.systemUptime
      model.play(playedB)
      var decoded = false
      for _ in 0..<200 {
        decoded = decoded || model.testDecodedFrame() != nil
        if model.elapsed >= saved && decoded { break }
        if ProcessInfo.processInfo.systemUptime - systemStarted > 5 { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      checks["smbRemountSystemResumeAndDecode"] =
        saved >= 7.9 && model.elapsed >= saved
        && model.elapsed < saved + 5 && decoded
        && ProcessInfo.processInfo.systemUptime - systemStarted < 6
      var diagnostics: [String: Any] = [
        "savedPosition": saved, "systemResumedAt": model.elapsed,
        "systemWaitSeconds": ProcessInfo.processInfo.systemUptime - systemStarted,
        "actualSMBMount": false, "fixtureDuration": model.duration,
      ]
      await settle()
      capture(window, to: output.appendingPathComponent("31-identity-remount-resume.png"))
      model.stopPlayback()
      if VLCPlaybackEngine.isAvailable {
        let position = model.resumeStore.position(for: rawMovieB.id)
        model.preferredEngine = .vlc
        let vlcStarted = ProcessInfo.processInfo.systemUptime
        model.play(playedB)
        for _ in 0..<240 {
          if model.elapsed >= position && (model.vlcEngine?.latest?.decodedVideo ?? 0) > 0 { break }
          if ProcessInfo.processInfo.systemUptime - vlcStarted > 5 { break }
          try? await Task.sleep(for: .milliseconds(50))
        }
        checks["smbRemountVLCResumeAndDecode"] =
          position >= 7.9 && model.elapsed >= position
          && model.elapsed < position + 5 && (model.vlcEngine?.latest?.decodedVideo ?? 0) > 0
          && ProcessInfo.processInfo.systemUptime - vlcStarted < 6
        diagnostics["vlcTarget"] = position
        diagnostics["vlcResumedAt"] = model.elapsed
        diagnostics["vlcWaitSeconds"] = ProcessInfo.processInfo.systemUptime - vlcStarted
        if let current = model.vlcEngine {
          let path = output.appendingPathComponent("32-identity-vlc-decoded.png")
          checks["smbIdentityVLCDecodedSnapshot"] = await current.snapshot(to: path)
        }
        model.stopPlayback()
      }
      let data = try JSONSerialization.data(
        withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: output.appendingPathComponent("identity-resume.json"))
    } catch { checks["smbIdentityFixtureFlow"] = false }
    return checks
  }
}

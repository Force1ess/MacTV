import AppKit
import MTVCore

extension UISmoke {
  static func smbOfflineSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String:
    Bool]
  {
    let source = model.captureLibrarySource()
    let originalSourceStore = model.sourceStore
    let originalProfileStore = model.smb.profileStore
    let originalIndex = model.smbLibraryIndex
    let originalMatches = model.metadataStore
    defer {
      model.smb.close()
      model.smb.connectionObserverForTesting = nil
      model.sourceSetup.close()
      model.sourceStore = originalSourceStore
      model.smb.profileStore = originalProfileStore
      model.smbLibraryIndex = originalIndex
      model.metadataStore = originalMatches
      model.restoreLibrarySource(source)
      model.navigate(.home)
    }
    var checks: [String: Bool] = [:]
    func safeArtwork(_ address: String?) -> Bool {
      guard let address else { return true }
      guard let url = URL(string: address) else { return false }
      return SMBCachedArtwork.isLocalReference(url)
    }
    func ready() async {
      for _ in 0..<200 {
        if !model.libraryRefreshing && !model.smb.profilesLoading { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
    }
    do {
      let root = output.appendingPathComponent("OfflineSourceMount")
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/MTV/Fixtures/ResumeFixture45.mp4")
      for path in ["Offline.Movie.2024.mp4", "TV/Example Show/Season 1/Example.Show.S01E01.mp4"] {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
          at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: fixture, to: file)
      }
      let poster = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/MTV/Fixtures/GeneratedPoster.png")
      for path in ["poster.jpg", "TV/Example Show/poster.jpg"] {
        try FileManager.default.linkItem(at: poster, to: root.appendingPathComponent(path))
      }
      let profile = try SMBProfile(
        address: "smb://fixture.invalid/Movies", username: "", guest: true, rememberPassword: false)
      let files = try LibraryScanner.scanResult(root: root).withSMBIdentity(
        profile: profile, mount: root
      ).items
      let indexes = SMBLibraryIndexStore(
        root: output.appendingPathComponent("offline-source/indexes"),
        artwork: SMBArtworkCache(disk: ArtworkCache.shared.disk))
      try await indexes.save(files, profile: profile, mount: root)
      let profiles = SMBProfileStore(
        file: output.appendingPathComponent("offline-source/connections.json"))
      try await profiles.upsert(profile)
      let selections = LibrarySourceStore(
        file: output.appendingPathComponent("offline-source/source.json"))
      try await selections.save(LibrarySourceSelection(smbProfileID: profile.id))
      model.sourceStore = selections
      model.smb.profileStore = profiles
      model.smbLibraryIndex = indexes
      model.metadataStore = MetadataStore(
        file: output.appendingPathComponent("offline-source/matches.json"))
      model.initializeLibrarySource()
      await ready()
      checks["smbOfflineStartupRestoresCatalogWithoutMount"] =
        model.library.count == 2
        && model.needsSMBReconnect && model.mediaRoot.isEmpty && !model.sourceNeedsSetup
        && model.library.allSatisfy { $0.url == nil && $0.localMetadata?.sourceReachable == false }
      checks["smbOfflineSourceAddressAndTimestampRestored"] =
        model.mediaSourceDisplay == profile.address
        && model.libraryIndexedAt != nil && model.libraryNeedsAttention
      let cold = ArtworkCache(disk: ArtworkCache.shared.disk, allowsNetwork: false)
      var decoded = 0
      for item in model.libraryCatalog.root {
        if let address = item.poster, let url = URL(string: address),
          await cold.image(for: url) != nil
        {
          decoded += 1
        }
      }
      checks["smbOfflineMovieAndSeriesCoversDecodeFromDisk"] = decoded == 2
      checks["smbOfflineCoverDecoderMakesNoNetworkRequest"] = await cold.networkRequests() == 0
      if let address = model.libraryCatalog.root.first?.poster, let url = URL(string: address) {
        let missing = ArtworkCache(
          disk: ArtworkDiskStore(root: output.appendingPathComponent("empty-artwork-cache")),
          allowsNetwork: true)
        let image = await missing.image(for: url)
        let requests = await missing.networkRequests()
        checks["smbVirtualArtworkMissNeverUsesNetwork"] = image == nil && requests == 0
      }
      model.navigate(.library)
      checks["smbOfflineLibraryHasReconnectFocus"] = model.focus.rows[1] == 5
        && model.smbReconnectColumn == 1 && model.savedSourcesColumn == 2 && model.overviewColumn == 3
      await settle()
      capture(window, to: output.appendingPathComponent("33-nas-offline-library.png"))
      model.focus.select(row: 1, column: 1)
      model.handle(.select)
      await ready()
      checks["smbOfflineReconnectOpensChosenProfile"] =
        model.smb.activeProfileID == profile.id
        && model.smb.phase == "form" && model.smb.controls[model.smb.selection] == .connect
      var requests = 0
      model.smb.connectionObserverForTesting = { location, _, _, guest in
        if location.shareURL.host == "fixture.invalid" && guest { requests += 1 }
      }
      model.handle(.select)
      for _ in 0..<100 {
        if model.smb.phase != "connecting" { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      checks["smbOfflineReconnectParametersDoNotCreateFakeMount"] =
        requests == 1 && model.needsSMBReconnect
        && model.player == nil && model.vlcEngine == nil
      model.smb.close()
      guard let movie = model.library.first(where: { $0.localMetadata?.episode == nil }) else {
        throw MTVError.message("离线测试缺少影片")
      }
      model.play(movie)
      await ready()
      checks["smbOfflinePlayRequestsConnectionInsteadOfStaleURL"] =
        model.smb.isPresented
        && model.smb.activeProfileID == profile.id && model.player == nil
      model.smb.close()
      let stored = try await indexes.load(profile: profile)
      let secondRoot = output.appendingPathComponent("DifferentFutureMount")
      let rebound = try stored?.binding(profile: profile, mount: secondRoot)
      checks["smbOfflineIndexRebindsOnlyCurrentURLs"] =
        rebound?.map(\.id) == files.map(\.id)
        && rebound?.allSatisfy {
          $0.url?.contains("DifferentFutureMount") == true
            && safeArtwork($0.poster) && safeArtwork($0.localMetadata?.seriesPoster)
        } == true
      let bytes = try Data(
        contentsOf: output.appendingPathComponent(
          "offline-source/indexes/" + profile.id.uuidString.lowercased() + ".json"))
      checks["smbOfflineIndexDoesNotRetainMountPaths"] = !String(decoding: bytes, as: UTF8.self)
        .contains(root.path)
      if let plugin = model.plugins.first(where: { $0.id == "mtv.example" }) {
        model.openModule(plugin)
        for _ in 0..<200 {
          if !model.loading { break }
          try? await Task.sleep(for: .milliseconds(50))
        }
        checks["smbOfflineStateDoesNotBlockIndependentModules"] =
          !model.online.isEmpty
          && model.activePlugin?.id == plugin.id && !model.smb.isPresented
      }
    } catch { checks["smbOfflineFixtureFlow"] = false }
    return checks
  }
}

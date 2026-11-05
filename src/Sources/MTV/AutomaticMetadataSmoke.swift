import AppKit
import MTVCore

extension UISmoke {
  struct BatchFixtureMetadata: MetadataSearching {
    var slow = false
    var limited = false
    func search(query: String, kind: MetadataKind, provider: MetadataProvider, token: String?)
      async throws -> [MetadataCandidate]
    {
      if limited { throw MTVError.rateLimited }
      if slow { try await Task.sleep(for: .seconds(5)) }
      guard ["Test Movie", "Example Show", "Ambiguous Movie"].contains(query) else {
        throw MTVError.message("Protected fixture was queried")
      }
      let year = query == "Ambiguous Movie" ? 2020 : (kind == .movie ? 2024 : nil)
      var values = [
        MetadataCandidate(
          provider: provider, externalID: 501, kind: kind,
          title: query, year: year, overview: "Automatic fixture match")
      ]
      if query == "Ambiguous Movie" {
        values.append(
          MetadataCandidate(
            provider: provider, externalID: 502, kind: kind,
            title: query, year: year))
      }
      return values
    }
  }

  static func automaticMetadataSmoke(model: AppModel, output: URL, window: NSWindow) async
    -> [String: Bool]
  {
    let source = model.captureLibrarySource()
    let store = model.metadataStore
    let client = model.metadata.client
    let tokenStore = model.metadata.tokenStore
    let token = model.metadata.tmdbToken
    defer {
      model.automaticMetadata.close()
      model.metadata.close()
      model.metadataStore = store
      model.metadata.client = client
      model.metadata.tokenStore = tokenStore
      model.metadata.tmdbToken = token
      model.restoreLibrarySource(source)
      model.navigate(.home)
    }
    var checks: [String: Bool] = [:]
    do {
      let root = output.appendingPathComponent("AutomaticLibrary")
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Library/Application Support/MTV/Fixtures/PlaybackFixture.mp4")
      for name in [
        "Test.Movie.2024.mp4", "Example.Show.S01E01.mp4",
        "Ambiguous.Movie.2020.mp4", "Protected.Movie.2021.mp4", "Manual.Movie.2022.mp4",
      ] {
        let file = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixture, to: file)
      }
      let sidecar = root.appendingPathComponent("Protected.Movie.2021.nfo")
      let nfo = Data("<movie><title>Protected Original</title><year>2021</year></movie>".utf8)
      try nfo.write(to: sidecar)
      let files = try LibraryScanner.scan(root: root)

      let limiter = AutomaticMetadataController()
      let rateTargets = AutomaticMetadata.targets(files: files.filter { ["Test Movie", "Ambiguous Movie"].contains($0.title) }, matches: [:])
      limiter.prepare(targets: rateTargets, client: BatchFixtureMetadata(limited: true),
        tokenStore: tokenStore, token: "OWNED-FAKE-TOKEN")
      limiter.start()
      for _ in 0..<100 { if limiter.phase == "done" { break }; try? await Task.sleep(for: .milliseconds(20)) }
      checks["metadataRateLimitStopsBatchIndependentlyOfTranslatedCopy"] = rateTargets.count == 2
        && limiter.phase == "done" && limiter.results.filter { $0.outcome == "failed" }.count == 1
        && limiter.results.count == 2
      limiter.close()

      model.metadataStore = MetadataStore(
        file: output.appendingPathComponent("automatic/matches.json"))
      let manual = files.first { $0.title == "Manual Movie" }!
      _ = try model.metadataStore.set(
        targetID: manual.id,
        candidate:
          MetadataCandidate(
            provider: .tmdb, externalID: 600, kind: .movie,
            title: "User choice", year: 2022))
      model.metadata.client = BatchFixtureMetadata()
      model.metadata.tmdbToken = "TEST_ONLY_IN_MEMORY"
      model.metadata.tokenStore = MetadataTokenStore(
        service: "local.mtv.batch.fixture." + UUID().uuidString)
      model.applyLibraryItems(files)
      model.prepareAutomaticMetadata()
      checks["automaticBatchFindsOnlyUnmatchedTargets"] =
        model.automaticMetadata.isPresented
        && model.automaticMetadata.targets.count == 3
      model.handle(.select)
      for _ in 0..<200 {
        if model.automaticMetadata.phase == "done" { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      let records = try model.metadataStore.load()
      checks["automaticUniqueMatchesSaved"] =
        model.automaticMetadata.matchedCount == 2
        && records.values.filter { $0.origin == .automatic }.count == 2
      checks["automaticManualMatchPreserved"] =
        records[manual.id]?.candidate.externalID == 600
        && records[manual.id]?.origin == .manual
      checks["automaticAmbiguityNeedsReview"] =
        model.automaticMetadata.reviewResults.count == 1
        && model.automaticMetadata.reviewResults.first?.item.title == "Ambiguous Movie"
      checks["automaticNFOUnchanged"] = try Data(contentsOf: sidecar) == nfo
      await settle()
      capture(window, to: output.appendingPathComponent("23-automatic-metadata.png"))
      model.automaticMetadata.selection = 1
      model.handle(.select)
      checks["automaticReviewOpensManualPicker"] =
        model.metadata.target?.title == "Ambiguous Movie"
        && !model.automaticMetadata.isPresented
      model.metadata.close()

      model.metadataStore = MetadataStore(
        file: output.appendingPathComponent("automatic-cancel/matches.json"))
      model.metadata.client = BatchFixtureMetadata(slow: true)
      model.applyLibraryItems(files)
      model.prepareAutomaticMetadata()
      model.automaticMetadata.activate()
      try? await Task.sleep(for: .milliseconds(100))
      model.handle(.back)
      try? await Task.sleep(for: .milliseconds(100))
      checks["automaticCancelStopsWrites"] =
        try model.metadataStore.load().isEmpty
        && model.automaticMetadata.phase == "done"
        && model.automaticMetadata.reviewResults.count == 4

      model.automaticMetadata.close()
      model.metadataStore = MetadataStore(
        file: output.appendingPathComponent("automatic-no-token/matches.json"))
      model.metadata.tmdbToken = nil
      model.applyLibraryItems([manual])
      model.prepareAutomaticMetadata()
      model.automaticMetadata.activate()
      for _ in 0..<100 {
        if model.automaticMetadata.phase == "done" { break }
        try? await Task.sleep(for: .milliseconds(50))
      }
      let missingTokenRecords = try model.metadataStore.load()
      checks["automaticMissingTokenReported"] =
        model.automaticMetadata.results.first?.outcome == "credentials"
        && missingTokenRecords.isEmpty

      if CommandLine.arguments.contains("--live-metadata") {
        let liveRoot = output.appendingPathComponent("AutomaticLiveLibrary")
        try FileManager.default.createDirectory(at: liveRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
          at: fixture, to: liveRoot.appendingPathComponent("Family.Guy.S01E01.mp4"))
        model.automaticMetadata.close()
        model.metadataStore = MetadataStore(
          file: output.appendingPathComponent("automatic-live/matches.json"))
        model.metadata.client = client
        model.applyLibraryItems(try LibraryScanner.scan(root: liveRoot))
        model.prepareAutomaticMetadata()
        model.automaticMetadata.activate()
        for _ in 0..<400 {
          if model.automaticMetadata.phase == "done" { break }
          try? await Task.sleep(for: .milliseconds(50))
        }
        checks["automaticLiveTVmazeMatched"] = try model.metadataStore.load().values.contains {
          $0.origin == .automatic && $0.candidate.externalID == 84
            && $0.candidate.title == "Family Guy"
        }
      }
    } catch {
      checks["automaticFixtureFlow"] = false
    }
    return checks
  }
}

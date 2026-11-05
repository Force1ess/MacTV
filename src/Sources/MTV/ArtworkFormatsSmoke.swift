import AppKit
import MTVCore

extension UISmoke {
  static func artworkFormatsSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    await model.waitForSourceSave()
    let previous = model.captureLibrarySource(), oldSource = model.sourceStore, oldSaved = model.savedSources.store, oldIndex = model.libraryIndex
    defer { model.sourceStore = oldSource; model.savedSources.store = oldSaved; model.libraryIndex = oldIndex
      model.notice = nil; model.detail = nil; model.restoreLibrarySource(previous); model.navigate(.home) }
    let root = output.appendingPathComponent("formats-owned"), media = root.appendingPathComponent("films")
    var checks: [String: Bool] = [:]
    func write(_ color: NSColor, type: NSBitmapImageRep.FileType, to url: URL) throws {
      let image = NSImage(size: NSSize(width: 96, height: 144))
      image.lockFocus(); color.setFill(); NSRect(x: 0, y: 0, width: 96, height: 144).fill(); image.unlockFocus()
      guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
        let data = bitmap.representation(using: type, properties: [.compressionFactor: 1]) else { throw CocoaError(.fileWriteUnknown) }
      try data.write(to: url)
    }
    func ready() async { for _ in 0..<300 { if !model.libraryRefreshing { return }; try? await Task.sleep(for: .milliseconds(50)) } }
    func pixels() -> [Double] {
      guard let view = window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [0, 0, 0] }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      var hits = [0, 0, 0], total = 0
      for y in stride(from: 0, to: bitmap.pixelsHigh, by: 16) { for x in stride(from: 0, to: bitmap.pixelsWide, by: 16) {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        let rgb = [color.redComponent, color.greenComponent, color.blueComponent]
        for c in 0..<3 where rgb[c] > 0.08 && rgb[c] > rgb[(c + 1) % 3] * 1.7 && rgb[c] > rgb[(c + 2) % 3] * 1.7 { hits[c] += 1 }
        total += 1
      } }
      return hits.map { Double($0) / Double(max(1, total)) }
    }
    func painted(_ channel: Int, threshold: Double = 0.01) async -> Bool {
      for _ in 0..<60 { if pixels()[channel] > threshold { return true }; try? await Task.sleep(for: .milliseconds(100)) }; return false
    }
    func refresh() async { model.scanLibrary(); await ready() }
    do {
      try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
      let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures")
      try FileManager.default.copyItem(at: base.appendingPathComponent("PlaybackFixture.mp4"), to: media.appendingPathComponent("Film.mp4"))
      let png = media.appendingPathComponent("poster.png"), jpeg = media.appendingPathComponent("poster.jpeg"), jpg = media.appendingPathComponent("poster.jpg"), webp = media.appendingPathComponent("poster.webp")
      try write(.red, type: .png, to: png)
      model.sourceStore = LibrarySourceStore(file: root.appendingPathComponent("selected.json"))
      model.savedSources.store = SavedLibrarySourcesStore(file: root.appendingPathComponent("sources.json"))
      model.libraryIndex = LibraryIndexStore(file: root.appendingPathComponent("index.json"))
      model.useLocalRoot(media); await ready(); await model.waitForSourceSave(); model.navigate(.library)
      let red = await painted(0)
      checks["formatsPNGPosterIsDiscoveredAndDecoded"] = red && model.library.first?.poster == png.absoluteString
      try write(.green, type: .jpeg, to: jpeg); await refresh()
      let green = await painted(1)
      checks["formatsJPEGPreferredWithinSameLocation"] = green && model.library.first?.poster == jpeg.absoluteString
      try write(.blue, type: .jpeg, to: jpg); await refresh()
      let blue = await painted(2)
      checks["formatsExistingJPGPriorityRemains"] = blue && model.library.first?.poster == jpg.absoluteString
      try FileManager.default.removeItem(at: jpg); await refresh()
      checks["formatsDeletedJPGSelectsJPEG"] = await painted(1)
      try FileManager.default.removeItem(at: jpeg); await refresh()
      checks["formatsDeletedJPEGSelectsPNG"] = await painted(0)
      try FileManager.default.removeItem(at: png)
      try FileManager.default.copyItem(at: base.appendingPathComponent("ArtworkFormats-v1/blue.webp"), to: webp); await refresh()
      let webpPainted = await painted(2)
      checks["formatsActualWebPDecodesInNativeGrid"] = webpPainted && model.library.first?.poster == webp.absoluteString
      let filmPoster = media.appendingPathComponent("Film.png")
      try write(.green, type: .png, to: filmPoster); await refresh()
      let specific = await painted(1)
      checks["formatsSpecificPosterPrecedesFolderFallback"] = specific && model.library.first?.poster == filmPoster.absoluteString
      let fanPNG = media.appendingPathComponent("fanart.png"), fanWebP = media.appendingPathComponent("fanart.webp"), fanJPG = media.appendingPathComponent("fanart.jpg")
      try write(.red, type: .png, to: fanPNG)
      try FileManager.default.copyItem(at: base.appendingPathComponent("ArtworkFormats-v1/blue.webp"), to: fanWebP); await refresh()
      if let item = model.library.first { model.selectContent(item) }
      checks["formatsPNGBackdropPaintsNativeDetail"] = await painted(0, threshold: 0.05)
      let reads = await ArtworkCache.shared.localReads(for: fanJPG)
      try Data("broken higher-priority image".utf8).write(to: fanJPG); await refresh(); await settle()
      let tried = await ArtworkCache.shared.localReads(for: fanJPG)
      checks["formatsBrokenJPGCanUseNextPNGBackdrop"] = tried > reads && pixels()[0] > 0.05
      try FileManager.default.removeItem(at: fanPNG); await refresh()
      checks["formatsWebPBackdropAppearsAfterPNGDeletion"] = await painted(2, threshold: 0.05)
      await settle(); capture(window, to: output.appendingPathComponent("webp-backdrop.png"))
      try write(.green, type: .jpeg, to: fanJPG); await refresh()
      checks["formatsRepairedJPGRestoresPrimaryBackdrop"] = await painted(1, threshold: 0.05)
      let priorReads = await ArtworkCache.shared.localReads(for: filmPoster)
      await refresh(); await settle()
      let warmReads = await ArtworkCache.shared.localReads(for: filmPoster)
      checks["formatsWarmRefreshKeepsPosterReadCount"] = priorReads == warmReads
      model.handle(.back)
    } catch { checks["formatsGeneratedFixtureSetup"] = false }
    return checks
  }
}

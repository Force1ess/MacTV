import AppKit
import MTVCore
import SwiftUI

extension UISmoke {
  static func artworkRefreshSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    await model.waitForSourceSave()
    let original = model.captureLibrarySource()
    let oldSource = model.sourceStore, oldSources = model.savedSources.store, oldIndex = model.libraryIndex
    defer {
      model.sourceStore = oldSource; model.savedSources.store = oldSources; model.libraryIndex = oldIndex
      model.notice = nil; model.restoreLibrarySource(original); model.navigate(.home)
    }
    let root = output.appendingPathComponent("artwork-refresh-owned"), media = root.appendingPathComponent("films")
    let poster = media.appendingPathComponent("poster.jpg"), fanart = media.appendingPathComponent("fanart.jpg")
    var checks: [String: Bool] = [:], diagnostics: [String: Any] = ["physicalScreenVerified": false, "viewBitmapUsed": true]
    func write(_ color: NSColor, to url: URL) throws {
      let image = NSImage(size: NSSize(width: 64, height: 96))
      image.lockFocus(); color.setFill(); NSRect(x: 0, y: 0, width: 64, height: 96).fill(); image.unlockFocus()
      guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
        let bytes = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 1.0]) else { throw CocoaError(.fileWriteUnknown) }
      try bytes.write(to: url)
    }
    func ready() async {
      for _ in 0..<300 { if !model.libraryRefreshing { return }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    func fractions(in target: NSView? = nil) -> [Double] {
      guard let view = target ?? window.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return [0, 0, 0] }
      view.cacheDisplay(in: view.bounds, to: bitmap)
      var hits = [0, 0, 0], total = 0
      for y in stride(from: 0, to: bitmap.pixelsHigh, by: 12) {
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 12) {
          guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
          let rgb = [color.redComponent, color.greenComponent, color.blueComponent]
          for channel in 0..<3 where rgb[channel] > 0.08 && rgb[channel] > rgb[(channel + 1) % 3] * 1.7 && rgb[channel] > rgb[(channel + 2) % 3] * 1.7 { hits[channel] += 1 }
          total += 1
        }
      }
      return hits.map { Double($0) / Double(max(1, total)) }
    }
    func painted(_ channel: Int, threshold: Double = 0.01) async -> Bool {
      for _ in 0..<60 {
        if fractions()[channel] > threshold { return true }
        try? await Task.sleep(for: .milliseconds(100))
      }
      return false
    }
    func dominant(_ image: NSImage?, _ channel: Int) -> Bool {
      guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil),
        let color = NSBitmapImageRep(cgImage: cg).colorAt(x: cg.width / 2, y: cg.height / 2)?.usingColorSpace(.deviceRGB) else { return false }
      let rgb = [color.redComponent, color.greenComponent, color.blueComponent]
      return rgb[channel] > 0.7 && rgb[channel] > rgb[(channel + 1) % 3] * 2 && rgb[channel] > rgb[(channel + 2) % 3] * 2
    }
    do {
      try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/PlaybackFixture.mp4")
      try FileManager.default.copyItem(at: fixture, to: media.appendingPathComponent("Film.mp4"))
      try Data("<movie><title>封面刷新测试</title></movie>".utf8).write(to: media.appendingPathComponent("Film.nfo"))
      try write(.red, to: poster); try write(.green, to: fanart)
      model.sourceStore = LibrarySourceStore(file: root.appendingPathComponent("selected.json"))
      model.savedSources.store = SavedLibrarySourcesStore(file: root.appendingPathComponent("sources.json"))
      model.libraryIndex = LibraryIndexStore(file: root.appendingPathComponent("index.json"))
      model.useLocalRoot(media); await ready(); await model.waitForSourceSave(); model.navigate(.library)
      checks["artworkInitialPosterPaintsRed"] = await painted(0)
      let isolated = ArtworkCache(disk: ArtworkDiskStore(root: root.appendingPathComponent("cache")), allowsNetwork: false)
      let before = ArtworkRefresh.shared.version(for: poster)
      let old = await isolated.image(for: poster, revision: before)
      try write(.blue, to: poster)
      let retained = await isolated.image(for: poster, revision: before)
      checks["artworkPriorRequestKeyRetainsItsOwnImage"] = dominant(old, 0) && retained === old
      model.scanLibrary(); await ready()
      let after = ArtworkRefresh.shared.version(for: poster)
      let bluePainted = await painted(2)
      checks["artworkSamePathReplacementChangesViewPixels"] = after != before && bluePainted
      let fresh = await isolated.image(for: poster, revision: after)
      checks["artworkNewRequestCannotUseRetiredCacheEntry"] = dominant(fresh, 2) && fresh !== old
      await settle(); capture(window, to: output.appendingPathComponent("poster-blue.png"))
      let reads = await ArtworkCache.shared.localReads(for: poster)
      model.scanLibrary(); await ready(); await settle()
      let warmReads = await ArtworkCache.shared.localReads(for: poster)
      checks["artworkUnchangedRefreshDoesNotReadPosterAgain"] = ArtworkRefresh.shared.version(for: poster) == after && warmReads == reads
      try Data("<movie><title>仅资料更新</title></movie>".utf8).write(to: media.appendingPathComponent("Film.nfo"))
      model.scanLibrary(); await ready(); await settle()
      let metadataReads = await ArtworkCache.shared.localReads(for: poster)
      checks["artworkNFOOnlyChangeKeepsImageRequest"] = metadataReads == reads && ArtworkRefresh.shared.version(for: poster) == after
      if let item = model.library.first { model.selectContent(item) }
      checks["artworkBackdropInitiallyPaintsGreen"] = await painted(1, threshold: 0.05)
      let posterBeforeBackdrop = ArtworkRefresh.shared.version(for: poster)
      try write(.blue, to: fanart); model.scanLibrary(); await ready()
      checks["artworkBackdropReplacementPaintsBlueIndependently"] = await painted(2, threshold: 0.05)
      checks["artworkBackdropChangeDoesNotInvalidatePoster"] = ArtworkRefresh.shared.version(for: poster) == posterBeforeBackdrop
      await settle(); capture(window, to: output.appendingPathComponent("backdrop-blue.png"))
      try write(.red, to: poster); try FileManager.default.removeItem(at: fanart)
      model.scanLibrary(); await ready()
      checks["artworkMissingBackdropUsesPosterPixels"] = await painted(0, threshold: 0.05)
      await settle(); capture(window, to: output.appendingPathComponent("backdrop-poster-fallback.png"))
      let fallbackReads = await ArtworkCache.shared.localReads(for: poster)
      model.scanLibrary(); await ready(); await settle()
      let fallbackWarmReads = await ArtworkCache.shared.localReads(for: poster)
      checks["artworkFallbackWarmRefreshDoesNotReadPosterAgain"] = fallbackWarmReads == fallbackReads
      let badBackdropReads = await ArtworkCache.shared.localReads(for: fanart)
      try Data("not an image".utf8).write(to: fanart); model.scanLibrary(); await ready(); await settle()
      let attemptedBadBackdrop = await ArtworkCache.shared.localReads(for: fanart)
      checks["artworkCorruptBackdropStillUsesPoster"] = attemptedBadBackdrop > badBackdropReads && fractions()[0] > 0.05
      try write(.green, to: fanart); model.scanLibrary(); await ready()
      checks["artworkRepairedPrimaryReplacesPosterFallback"] = await painted(1, threshold: 0.05)
      try FileManager.default.removeItem(at: fanart); try write(.blue, to: poster)
      model.scanLibrary(); await ready()
      checks["artworkPosterFallbackTracksReplacement"] = await painted(2, threshold: 0.05)
      try write(.blue, to: fanart); model.scanLibrary(); await ready()
      model.handle(.back)
      try Data("not an image".utf8).write(to: poster); model.scanLibrary(); await ready(); await settle()
      let badPixels = fractions()
      checks["artworkBadReplacementClearsRetiredPixels"] = badPixels[0] < 0.005 && badPixels[2] < 0.005
      try write(.green, to: poster); model.scanLibrary(); await ready()
      checks["artworkRepairedImagePaintsGreen"] = await painted(1)
      let forceBefore = ArtworkRefresh.shared.version(for: poster)
      model.scanLibrary(forceFull: true); await ready()
      let forcedPainted = await painted(1)
      checks["artworkFullRecognitionRefreshesLocalPixels"] = ArtworkRefresh.shared.version(for: poster) != forceBefore && forcedPainted
      try FileManager.default.removeItem(at: poster); model.scanLibrary(); await ready(); await settle()
      checks["artworkDeletionRemovesImageAddressAndPixels"] = model.library.first?.poster == nil && fractions()[1] < 0.005
      let remote = URL(string: "https://fixture.invalid/poster.jpg")!
      let requests = await isolated.networkRequests()
      checks["artworkLocalRefreshDoesNotVersionRemoteOrUseNetwork"] = ArtworkRefresh.shared.version(for: remote) == 0 && requests == 0
      let outside = root.appendingPathComponent("outside.jpg")
      try write(.red, to: outside)
      let scope = ArtworkFileAccess.within(URL(fileURLWithPath: try ArtworkFileReader.canonicalPath(media)))
      let permitted = media.appendingPathComponent("permitted.jpg")
      try write(.green, to: permitted)
      let admittedImage = await isolated.image(for: permitted, revision: 1, access: scope)
      let disallowed = await isolated.image(for: outside, revision: 1, access: scope)
      checks["artworkScopedDecoderRejectsOutsideImage"] = dominant(admittedImage, 1) && disallowed == nil
      let policy = ArtworkRefresh()
      let managed = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Mounts/" + UUID().uuidString)
      try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: managed) }
      let managedImage = managed.appendingPathComponent("poster.jpg")
      checks["artworkPrivateMountWithoutLeaseIsDenied"] = policy.access(for: managedImage) == .denied
      policy.setShareRoots([managed])
      let admitted = policy.access(for: managedImage) != .denied
      policy.setShareRoots([])
      checks["artworkRetiredMountScopeIsRevoked"] = admitted && policy.access(for: managedImage) == .denied
      try write(.green, to: managedImage)
      let fallbackOutsideReads = await ArtworkCache.shared.localReads(for: outside)
      let host = NSHostingView(rootView: Artwork(address: managedImage.absoluteString,
        fallbackAddress: outside.absoluteString, refresh: policy).frame(width: 240, height: 180))
      host.frame = NSRect(x: 0, y: 0, width: 240, height: 180)
      window.contentView?.addSubview(host)
      defer { host.removeFromSuperview() }
      await settle()
      let deniedPixels = fractions(in: host)
      let deniedOutsideReads = await ArtworkCache.shared.localReads(for: outside)
      checks["artworkDeniedPrimaryCannotUseOutsideFallback"] = deniedPixels[0] < 0.005 && deniedOutsideReads == fallbackOutsideReads
      policy.setShareRoots([managed])
      var admittedPixels = false
      for _ in 0..<60 {
        if fractions(in: host)[1] > 0.1 { admittedPixels = true; break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      checks["artworkScopedPrimaryPaintsOnlyWithOwnLease"] = admittedPixels
      policy.setShareRoots([])
      for _ in 0..<60 {
        if fractions(in: host)[1] < 0.005 { break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      let retiredPixels = fractions(in: host)
      let retiredOutsideReads = await ArtworkCache.shared.localReads(for: outside)
      checks["artworkRevocationClearsPixelsWithoutOutsideFallback"] = retiredPixels[0] < 0.005 && retiredPixels[1] < 0.005 && retiredOutsideReads == fallbackOutsideReads
      host.rootView = Artwork(address: nil, fallbackAddress: outside.absoluteString,
        fallbackBlur: 18, refresh: policy).frame(width: 240, height: 180)
      var explicitFallback = false
      for _ in 0..<60 {
        if fractions(in: host)[0] > 0.1 { explicitFallback = true; break }
        try? await Task.sleep(for: .milliseconds(100))
      }
      checks["artworkExplicitFallbackWithoutPrimaryPaintsItsOwnImage"] = explicitFallback
      diagnostics["fallbackPosterReads"] = fallbackReads; diagnostics["fallbackWarmPosterReads"] = fallbackWarmReads
      diagnostics["initialRevision"] = before; diagnostics["replacementRevision"] = after
      diagnostics["warmPosterReads"] = warmReads; diagnostics["posterReadsBeforeWarmRefresh"] = reads
      diagnostics["badImageFractions"] = badPixels
      await model.waitForSourceSave()
    } catch { checks["artworkRefreshFixtureSetup"] = false; diagnostics["error"] = error.localizedDescription }
    if let data = try? JSONSerialization.data(withJSONObject: diagnostics, options: [.prettyPrinted, .sortedKeys]) {
      try? data.write(to: output.appendingPathComponent("artwork-refresh-diagnostics.json"))
    }
    return checks
  }
}

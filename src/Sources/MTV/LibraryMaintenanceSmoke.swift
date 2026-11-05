import AppKit
import MTVCore

extension UISmoke {
  @MainActor static func libraryMaintenanceSmoke(model: AppModel, output: URL) async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    let root = output.appendingPathComponent("owned-library")
    func wait(_ predicate: () -> Bool) async {
      for _ in 0..<300 { if predicate() { return }; try? await Task.sleep(for: .milliseconds(40)) }
    }
    do {
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
      try Data().write(to: root.appendingPathComponent("First (2020).mkv"))
      model.useLocalRoot(root); await wait { !model.libraryRefreshing && model.libraryFilesForMaintenance.count == 1 }
      checks["initialOwnedLibraryReady"] = model.libraryFilesForMaintenance.count == 1
      try Data().write(to: root.appendingPathComponent("[Group] New Show - 02 [1080p].m2ts"))
      model.libraryMaintenance.refresh(model: model)
      await wait { !model.libraryRefreshing && model.libraryFilesForMaintenance.count == 2 }
      checks["maintenanceDiscoversNewDownloadWithoutScanButton"] = model.libraryFilesForMaintenance.count == 2
      checks["newEpisodeBecomesShowCard"] = model.libraryFilesForMaintenance.contains { $0.localMetadata?.seriesTitle == "New Show" }
      try Data().write(to: root.appendingPathComponent("Third (2021).mkv"))
      model.libraryMaintenance.refresh(model: model)
      try? await Task.sleep(for: .milliseconds(200))
      checks["eventBurstDoesNotLaunchRepeatedScans"] = model.libraryFilesForMaintenance.count == 2 && !model.libraryRefreshing
      model.libraryMaintenance.sourceChanged()
      model.libraryMaintenance.refresh(model: model)
      await wait { !model.libraryRefreshing && model.libraryFilesForMaintenance.count == 3 }
      checks["sourceChangeResetsRefreshDebounce"] = model.libraryFilesForMaintenance.count == 3
      let fixture = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MTV/Fixtures/IndependentLongGOP45-v1.mp4")
      model.preferredEngine = .system
      model.beginPlayback(url: fixture, item: MediaItem(id: "owned-maintenance-player", title: "Owned", url: fixture.absoluteString), fromBeginning: true)
      await wait { model.playbackPresented }
      model.libraryMaintenance.sourceChanged()
      try Data().write(to: root.appendingPathComponent("Fourth (2022).mkv"))
      model.libraryMaintenance.refresh(model: model)
      checks["backgroundScanDoesNotCompeteWithPlayback"] = model.libraryFilesForMaintenance.count == 3 && !model.libraryRefreshing
      model.stopPlayback(); await model.waitForPlaybackShutdown()
      model.libraryMaintenance.refresh(model: model)
      await wait { !model.libraryRefreshing && model.libraryFilesForMaintenance.count == 4 }
      checks["idleRefreshResumesAfterPlayback"] = model.libraryFilesForMaintenance.count == 4
    } catch { checks["ownedFixtureSetup"] = false }
    return checks
  }
}

import AppKit
import MTVCore

extension UISmoke {
  static func modulePartsSmoke(model: AppModel, output: URL, window: NSWindow) async -> [String: Bool] {
    var checks: [String: Bool] = [:]
    defer { model.stopPlayback(); model.notice = nil; model.navigate(.home) }
    func wait() async {
      for _ in 0..<300 { if !model.loading { return }; try? await Task.sleep(for: .milliseconds(50)) }
    }
    guard let example = model.plugins.first(where: { $0.id == "mtv.example" }) else { return ["partsExampleInstalled": false] }
    model.openModule(example); await wait()
    guard let card = model.online.first else { return ["partsExampleCardLoaded": false] }
    let parent = model.online.map(\.id)
    model.focus.select(row: 2, column: 0); model.handle(.select)
    checks["partsVideoOpensDetailWithIndependentPlayAction"] = model.detail?.id == card.id
      && model.canOpenCollection(card) && model.detailAction == 0 && !card.isFolder
    await settle(); capture(window, to: output.appendingPathComponent("parts-detail.png"))
    model.handle(.right); model.handle(.select); await wait()
    checks["partsRemoteEntersNativeCollection"] = model.detail == nil && model.modulePath.count == 1
      && model.online.count == 2 && model.online[1].reference == "example-part-2"
    checks["partsChildrenDoNotRecursivelyOfferCollection"] = model.online.allSatisfy { $0.collectionReference == nil }
    await settle(); capture(window, to: output.appendingPathComponent("parts-list.png"))
    model.focus.select(row: 2, column: 1); model.handle(.select)
    checks["partsSecondSelectionKeepsItsReference"] = model.detail?.reference == "example-part-2"
      && model.detailAction == 0 && model.detail.map { model.detailControls(for: $0) } == [.play, .watchlist, .close]
    model.handle(.right); model.handle(.right)
    checks["partsChildCloseFocusIsBounded"] = model.detailAction == 2 && model.detail.map { model.detailControls(for: $0).last } == .close
    model.handle(.back); model.handle(.back)
    checks["partsBackRestoresParentAndFocus"] = model.modulePath.isEmpty && model.online.map(\.id) == parent
      && model.focus.row == 2 && model.focus.column == 0 && model.detail == nil
    model.handle(.select); model.handle(.right); model.handle(.right); model.handle(.right)
    checks["partsDetailCloseKeepsLastPositionAfterWatchlist"] = model.detailAction == 3 && model.detailControls(for: card)[model.detailAction] == .close
    model.handle(.select)
    checks["partsDetailCloseReturnsWithoutEnteringFolder"] = model.detail == nil && model.modulePath.isEmpty
    model.handle(.select); model.handle(.right); model.handle(.select); model.handle(.back)
    await settle()
    checks["partsBackCancelsPendingFolderLoad"] = model.modulePath.isEmpty && !model.loading && model.online.map(\.id) == parent
    if CommandLine.arguments.contains("--live-services") {
      guard let bili = model.plugins.first(where: { $0.id == "mtv.bilibili" }) else { checks["partsRealBilibiliModulePresent"] = false; return checks }
      do {
        let reference = "BV1wD4y1o7AS"
        let firstData = try await PluginClient.execute(bili, action: "browse", input: ["folder": reference], sessionAccess: .guest)
        let first = try JSONDecoder().decode(PluginPage.self, from: firstData)
        let items = try PluginContentValidator.normalize(first.items, manifest: bili.manifest)
        checks["partsRealFirstPageThroughSandboxAndBroker"] = items.count == 100 && first.next == "2"
          && items.first?.reference?.hasPrefix(reference + ":") == true && items[1].reference != items.first?.reference
        let nextData = try await PluginClient.execute(bili, action: "browse", input: ["folder": reference, "page": "2"], sessionAccess: .guest)
        let next = try JSONDecoder().decode(PluginPage.self, from: nextData)
        let tail = try PluginContentValidator.normalize(next.items, manifest: bili.manifest)
        checks["partsRealSecondPageHasIndependentIDs"] = tail.count == 100 && next.next == nil
          && Set(items.map(\.id)).isDisjoint(with: tail.map(\.id))
      } catch { checks["partsRealFirstPageThroughSandboxAndBroker"] = false }
    }
    return checks
  }
}

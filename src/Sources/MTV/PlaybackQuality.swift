import Foundation
import MTVCore
import SwiftUI

struct PlaybackQualityResume {
  let itemID: String
  let position: Double
  let paused: Bool
}

extension AppModel {
  var hasBilibiliQualityMenu: Bool { playingItem?.source == "mtv.bilibili" && !bilibiliQualityOptions.isEmpty }
  func receiveBilibiliQuality(_ stream: PlaybackDescriptor) {
    var seen = Set<Int>()
    bilibiliQualityOptions = Array((stream.qualities ?? []).filter {
      (1...120).contains($0.id) && !$0.title.isEmpty && $0.title.count <= 100
        && ($0.reason?.count ?? 0) <= 300 && seen.insert($0.id).inserted
    }.prefix(32))
    bilibiliActualQuality = stream.quality
    bilibiliActualQualityTitle = String((stream.qualityTitle ?? stream.height.map { "\($0)p" } ?? L("平台画质")).prefix(100))
    bilibiliQualityNote = String((stream.note ?? "").prefix(300))
  }
  func presentPlaybackQuality() {
    guard hasBilibiliQualityMenu else { return }
    cancelPlayerScrub(); qualitySelection = 0
    playbackQualityVisible = true; showPlayerControls()
  }
  func choosePlaybackQuality(_ index: Int) {
    guard let item = playingItem, item.source == "mtv.bilibili", (0...bilibiliQualityOptions.count).contains(index) else { return }
    let preference: String
    if index == 0 { preference = "auto" }
    else {
      let option = bilibiliQualityOptions[index - 1]
      guard option.available else { return }
      preference = String(option.id)
    }
    playbackQualityVisible = false
    if preference != "auto", preference == bilibiliQualityPreference, bilibiliActualQuality == Int(preference) { showPlayerControls(); return }
    saveProgress()
    let nativePosition = player?.currentTime().seconds ?? elapsed
    let nativeDuration = player?.currentItem?.duration.seconds
    let knownDuration = nativeDuration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? duration
    pendingQualityResume = PlaybackQualityResume(itemID: item.id, position: PlaybackTimeline.target(nativePosition, duration: knownDuration) ?? 0, paused: paused)
    player?.pause(); paused = true
    bilibiliQualityPreference = preference
    if !CommandLine.arguments.contains("--ui-smoke") { UserDefaults.standard.set(preference, forKey: "mtv.bilibili.quality") }
    play(item)
  }
}

struct PlaybackQualityPanel: View {
  @ObservedObject var model: AppModel
  var body: some View {
    TVDialog(title: L("清晰度"), subtitle: L("当前：\(model.bilibiliActualQualityTitle)"), symbol: "tv") {
      VStack(alignment: .leading, spacing: 14) {
        ScrollViewReader { scroll in
          ScrollView {
            VStack(spacing: 8) {
              row(0, L("最高可用"), "", true)
              ForEach(Array(model.bilibiliQualityOptions.enumerated()), id: \.element.id) { index, option in
                row(index + 1, option.title, option.available ? (model.bilibiliActualQuality == option.id ? L("正在播放") : "") : option.reason ?? L("暂不可用"), option.available)
              }
            }.padding(6)
          }.frame(maxHeight: 380)
            .onChange(of: model.qualitySelection) { _, value in scroll.scrollTo(value, anchor: .center) }
        }
      }
    }
  }
  private func row(_ index: Int, _ title: String, _ detail: String, _ available: Bool) -> some View {
    TVButton(selected: model.qualitySelection == index, action: { model.choosePlaybackQuality(index) }, hover: { model.qualitySelection = index }) {
      HStack {
        Text(title).font(.system(size: 23, weight: .medium)); Spacer()
        Text(detail).font(.system(size: 15)).foregroundStyle(.secondary)
      }.padding(20).frame(maxWidth: .infinity).opacity(available ? 1 : 0.45)
    }.id(index)
  }
}

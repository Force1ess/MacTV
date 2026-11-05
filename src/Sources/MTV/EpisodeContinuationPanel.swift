import SwiftUI
import MTVCore

struct EpisodeContinuationPanel: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject var model: AppModel
  var body: some View {
    if let plan = model.episodeChoices {
      ZStack {
        TVPopupBackdrop()
        VStack(alignment: .leading, spacing: 20) {
          Text(plan.label).font(.system(size: 34, weight: .bold))
          if !plan.message.isEmpty { Text(plan.message).font(.system(size: 18)).foregroundStyle(.secondary).lineLimit(4) }
          ScrollViewReader { scroll in
            ScrollView {
              LazyVStack(spacing: 12) {
                ForEach(Array(plan.candidates.enumerated()), id: \.element.id) { index, item in
                  TVButton(selected: model.episodeChoiceIndex == index,
                    action: { model.episodeChoiceIndex = index; model.activateEpisodeChoice() }, hover: { model.episodeChoiceIndex = index }) {
                    VStack(alignment: .leading, spacing: 8) {
                      Text(item.title).font(.system(size: 23, weight: .semibold)).lineLimit(2)
                      Text(item.subtitle).font(.system(size: 17)).foregroundStyle(.secondary)
                      Text(SMBMediaIdentity.displayFilename(item) ?? "影片文件 \(index + 1)")
                        .font(.system(size: 15)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                      if item.localMetadata?.sourceReachable == false { Text(L("缓存条目，播放前检查片源连接")).font(.system(size: 14)).foregroundStyle(.orange) }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                  }.id(index)
                }
                TVButton(selected: model.episodeChoiceIndex == plan.candidates.count,
                  action: { model.dismissEpisodeChoices() }, hover: { model.episodeChoiceIndex = plan.candidates.count }) {
                  Label("返回播放", systemImage: "chevron.left").font(.system(size: 20)).padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }.id(plan.candidates.count)
              }.padding(14)
            }.scrollIndicators(.hidden)
              .onChange(of: model.episodeChoiceIndex) { _, index in withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { scroll.scrollTo(index, anchor: .center) } }
          }
        }.padding(34).frame(width: 800, height: 640)
          .tvPopupSurface(radius: 28)
      }
    }
  }
}

import MTVCore
import SwiftUI

struct AutomaticMetadataPanel: View {
  @ObservedObject var controller: AutomaticMetadataController
  var body: some View {
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 18) {
        Text(L("识别影片与海报")).font(.system(size: 32, weight: .bold))
        if let report = controller.inventoryReport {
          let summary = report.summary
          HStack(spacing: 28) {
            metric("视频文件", summary.files)
            metric("剧集", summary.series)
            metric("多版本", summary.versionCollections)
            metric("附加内容", summary.extraFiles)
            metric("缺少海报", summary.missingPosters)
          }.padding(22).frame(maxWidth: .infinity).background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
          if summary.malformedTitles + summary.unparsedEpisodes + summary.unreachableFiles > 0 {
            Label(L("部分影片资料仍需整理，尚未全部识别完成。"), systemImage: "exclamationmark.circle").foregroundStyle(.orange)
          }
        }
        if controller.phase == "ready" {
          Text(controller.targets.isEmpty ? L("没有需要匹配的条目") : L("将检查 \(controller.targets.count) 个缺失条目"))
          if !controller.targets.isEmpty { button(0, "开始识别") }
          button(controller.targets.isEmpty ? 0 : 1, "返回")
        } else if controller.phase == "running" {
          ProgressView(
            value: Double(controller.results.count), total: Double(max(1, controller.targets.count))
          )
          Text(controller.currentTitle).font(.title2)
          Text(
            L("已处理 \(controller.results.count) / \(controller.targets.count)，匹配 \(controller.matchedCount) 项")
          ).foregroundStyle(.secondary)
          button(0, "取消")
        } else {
          Text(L("已匹配 \(controller.matchedCount) 项 · 待确认 \(controller.reviewResults.count) 项")).font(
            .title2)
          if !controller.currentTitle.isEmpty {
            Text(controller.currentTitle).foregroundStyle(.secondary)
          }
          button(0, "完成")
          ScrollViewReader { scroll in
            ScrollView {
              VStack(spacing: 10) {
                ForEach(Array(controller.reviewResults.enumerated()), id: \.element.id) {
                  index, result in
                  TVButton(
                    selected: controller.selection == index + 1,
                    action: {
                      controller.selection = index + 1
                      controller.activate()
                    },
                    hover: { controller.selection = index + 1 }
                  ) {
                    VStack(alignment: .leading, spacing: 6) {
                      Text(result.item.title).font(.system(size: 20, weight: .semibold))
                      Text(LT(result.message)).font(.system(size: 15)).foregroundStyle(.secondary)
                        .lineLimit(2)
                    }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                  }.id(index + 1)
                }
              }.padding(6)
            }.scrollIndicators(.hidden)
              .onChange(of: controller.selection) { _, index in
                scroll.scrollTo(index, anchor: .center)
              }
          }
        }
        Spacer(minLength: 0)
      }.padding(36).frame(width: 960, height: 630)
        .tvPopupSurface(radius: 28)
    }
  }
  private func metric(_ label: String, _ value: Int) -> some View {
    VStack(alignment: .leading, spacing: 7) {
      Text(String(value)).font(.system(size: 27, weight: .semibold)).monospacedDigit()
      Text(label).font(.system(size: 14)).foregroundStyle(.secondary)
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
  private func button(_ index: Int, _ title: String) -> some View {
    TVButton(
      selected: controller.selection == index,
      action: {
        controller.selection = index
        controller.activate()
      },
      hover: { controller.selection = index }
    ) { Text(LT(title)).font(.title3).padding(18).frame(maxWidth: .infinity) }
  }
}

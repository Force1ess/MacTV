import MTVCore
import SwiftUI

struct MetadataPanel: View {
  @ObservedObject var controller: MetadataController
  var body: some View {
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 18) {
        Text(L("匹配影片信息")).font(.system(size: 32, weight: .bold))
        Text(controller.target?.title ?? "").foregroundStyle(.secondary)
        if controller.loading { ProgressView("正在查找…") }
        if !controller.message.isEmpty {
          Text(LT(controller.message)).foregroundStyle(.secondary).lineLimit(2)
        }
        control(0, "修改片名", controller.query)
        HStack(spacing: 12) {
          compactControl(1, "数据源", controller.provider == .tvmaze ? L("TVmaze · 剧集") : "TMDB")
          compactControl(2, L("设置令牌"), controller.tokenConfigured ? L("已配置 TMDB") : L("配置 TMDB"))
          compactControl(3, L("移除令牌"), L("仅 MacTV"))
          compactControl(4, L("恢复原始"), L("撤销匹配"))
        }
        ScrollViewReader { scroll in
          ScrollView {
            VStack(spacing: 12) {
              ForEach(Array(controller.candidates.enumerated()), id: \.element.id) {
                index, candidate in
                TVButton(
                  selected: controller.selection == index + 5,
                  action: {
                    controller.selection = index + 5
                    controller.activate()
                  },
                  hover: { controller.selection = index + 5 }
                ) {
                  HStack(spacing: 20) {
                    Artwork(address: candidate.poster).frame(width: 54, height: 81).clipShape(
                      RoundedRectangle(cornerRadius: 7))
                    VStack(alignment: .leading, spacing: 7) {
                      Text(candidate.title).font(.system(size: 22, weight: .semibold))
                      Text(candidate.year.map(String.init) ?? L("年份未知")).foregroundStyle(.secondary)
                      Text(candidate.overview).font(.system(size: 14)).foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                    Spacer()
                  }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                }.id(index + 5)
              }
              control(controller.controlCount - 1, "返回", "")
            }.padding(6)
          }.scrollIndicators(.hidden)
            .onChange(of: controller.selection) { _, index in
              withAnimation(.easeInOut(duration: 0.18)) { scroll.scrollTo(index, anchor: .center) }
            }
        }
        HStack {
          Spacer()
          if let candidate = controller.candidates.first {
            Link(
              L("信息来源：\(candidate.provider == .tvmaze ? "TVmaze" : "TMDB")"),
              destination: candidate.attribution
            ).font(.system(size: 13))
          }
        }
      }.padding(32).frame(width: 1000, height: 650)
        .tvPopupSurface(radius: 26)
    }
  }
  private func compactControl(_ index: Int, _ title: String, _ value: String) -> some View {
    TVButton(
      selected: controller.selection == index,
      action: {
        controller.selection = index
        controller.activate()
      },
      hover: { controller.selection = index }
    ) {
      VStack(alignment: .leading, spacing: 5) {
        Text(LT(title)).font(.system(size: 17, weight: .semibold))
        Text(value).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
      }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private func control(_ index: Int, _ title: String, _ value: String) -> some View {
    TVButton(
      selected: controller.selection == index,
      action: {
        controller.selection = index
        controller.activate()
      },
      hover: { controller.selection = index }
    ) {
      HStack {
        Text(LT(title)).font(.system(size: 19, weight: .medium))
        Spacer()
        Text(value).font(.system(size: 16)).foregroundStyle(.secondary).lineLimit(1)
      }
      .padding(18).frame(maxWidth: .infinity)
    }.id(index)
  }
}

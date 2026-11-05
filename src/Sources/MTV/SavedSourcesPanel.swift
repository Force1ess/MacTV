import MTVCore
import SwiftUI

struct SavedSourcesPanel: View {
  @ObservedObject var controller: SavedSourcesController
  var body: some View {
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 22) {
        Text(L("影片来源")).font(.system(size: 34, weight: .semibold))
        if !controller.message.isEmpty { Text(controller.message).foregroundStyle(.orange).lineLimit(3) }
        if controller.loading { ProgressView("正在读取来源…") }
        ScrollViewReader { scroll in
          ScrollView {
            VStack(spacing: 12) {
              ForEach(Array(controller.sources.enumerated()), id: \.element.id) { index, source in
                HStack(spacing: 10) {
                  TVButton(selected: controller.selection == index && controller.column == 0,
                    action: { controller.selection = index; controller.column = 0; controller.activate() },
                    hover: { controller.selection = index; controller.column = 0 }) {
                    HStack(spacing: 20) {
                      Image(systemName: source.path == nil ? "externaldrive.connected.to.line.below" : "folder.fill")
                        .font(.system(size: 25)).foregroundStyle(.secondary)
                      Text(source.title).font(.system(size: 23, weight: .semibold)).lineLimit(1)
                      Spacer()
                      if let current = controller.current, source.matches(current) {
                        Label(L("当前"), systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                      }
                    }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                  }
                  TVButton(selected: controller.selection == index && controller.column == 1,
                    action: { controller.selection = index; controller.column = 1; controller.activate() },
                    hover: { controller.selection = index; controller.column = 1 }) {
                    Image(systemName: "minus.circle").font(.system(size: 23)).padding(24)
                  }.accessibilityLabel(L("移除\(source.title)"))
                }.id("source-" + source.id.uuidString)
              }
              action(controller.sources.count, title: "添加影片文件夹", symbol: "folder.badge.plus")
              action(controller.sources.count + 1, title: "添加或选择 NAS", symbol: "externaldrive.badge.plus")
              action(controller.sources.count + 2, title: "完成", symbol: "arrow.uturn.backward")
            }.padding(12)
          }.onChange(of: controller.selection) { _, row in scroll.scrollTo(controller.rowID(row), anchor: .center) }
        }
      }.padding(40).frame(width: 1000, height: 660)
        .tvPopupSurface(radius: 30)
    }
  }
  private func action(_ index: Int, title: String, symbol: String) -> some View {
    TVButton(selected: controller.selection == index,
      action: { controller.selection = index; controller.activate() },
      hover: { controller.selection = index; controller.column = 0 }) {
      Label(title, systemImage: symbol).font(.system(size: 21, weight: .medium))
        .padding(22).frame(maxWidth: .infinity, alignment: .leading)
    }.id(controller.rowID(index))
  }
}

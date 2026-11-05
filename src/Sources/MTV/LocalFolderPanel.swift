import MTVCore
import SwiftUI

struct LocalFolderPanel: View {
  @ObservedObject var controller: LocalFolderController
  var body: some View {
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 20) {
        Label(LT(controller.title), systemImage: "folder.fill").font(.system(size: 32, weight: .bold))
        Text(controller.directory?.path ?? L("选择一个位置开始浏览"))
          .font(.system(size: 17)).foregroundStyle(.secondary).lineLimit(2)
        if controller.loading { ProgressView(L("正在读取目录…")) }
        if !controller.message.isEmpty {
          Text(LT(controller.message)).foregroundStyle(.orange).font(.system(size: 16)).lineLimit(4)
        }
        HStack(alignment: .top, spacing: 24) {
          VStack(spacing: 8) {
            ForEach(
              Array(controller.controls.enumerated().prefix(controller.sidebarCount)), id: \.offset
            ) { index, control in
              entry(index, control, compact: true)
            }
          }.frame(width: 310)
          Rectangle().fill(.white.opacity(0.08)).frame(width: 1)
          ScrollViewReader { scroll in
            ScrollView {
              LazyVStack(spacing: 8) {
                ForEach(
                  Array(controller.controls.enumerated().dropFirst(controller.sidebarCount)),
                  id: \.offset
                ) { index, control in
                  entry(index, control, compact: false).id(index)
                }
                if !controller.loading && controller.folders.isEmpty {
                  Text(L("这里没有子文件夹")).foregroundStyle(.secondary).padding(30)
                }
              }.padding(.horizontal, 16).padding(.vertical, 10)
            }.scrollIndicators(.hidden)
              .onChange(of: controller.selection) { _, index in
                withAnimation(.easeInOut(duration: 0.18)) {
                  scroll.scrollTo(index, anchor: .center)
                }
              }
          }
        }.frame(maxHeight: .infinity)
        if controller.total > controller.folders.count {
          Text(L("显示 \(controller.folders.count)／\(controller.total) 个文件夹"))
            .font(.system(size: 14)).foregroundStyle(.secondary)
        }
      }.padding(36).frame(width: 1000, height: 680)
        .tvPopupSurface(radius: 28)
    }
  }
  private func entry(_ index: Int, _ control: LocalFolderControl, compact: Bool) -> some View {
    TVButton(
      selected: controller.selection == index,
      action: {
        controller.selection = index
        controller.activate()
      },
      hover: { controller.selection = index }
    ) {
      HStack(spacing: 14) {
        Image(systemName: symbol(control)).frame(width: 24)
        Text(label(control)).font(.system(size: compact ? 17 : 20, weight: .medium)).lineLimit(1)
        Spacer(minLength: 0)
        if case .folder = control { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
      }.padding(compact ? 14 : 18).frame(maxWidth: .infinity, alignment: .leading)
    }
  }
  private func label(_ value: LocalFolderControl) -> String {
    switch value {
    case .use: return L("使用这个目录")
    case .parent: return L("返回上层文件夹")
    case .home: return L("个人文件夹")
    case .movies: return LT(controller.shortcutTitle)
    case .volumes: return L("磁盘与已挂载共享")
    case .address: return L("输入目录路径")
    case .systemPicker: return L("使用 macOS 文件选择器")
    case .close: return L("返回")
    case .folder(let url): return url.lastPathComponent
    }
  }
  private func symbol(_ value: LocalFolderControl) -> String {
    switch value {
    case .use: return "checkmark.circle"
    case .parent: return "arrow.up"
    case .home: return "house"
    case .movies: return "film"
    case .volumes: return "externaldrive"
    case .address: return "keyboard"
    case .systemPicker: return "macwindow"
    case .close: return "arrow.uturn.backward"
    case .folder: return "folder"
    }
  }
}

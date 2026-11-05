import MTVCore
import SwiftUI

struct ContinueWatchingRow: View {
  @ObservedObject var model: AppModel
  var body: some View { SavedContentShelf(model: model, shelf: .history) }
}
struct SavedContentShelf: View {
  @ObservedObject var model: AppModel
  let shelf: SavedShelf
  private var row: Int { shelf == .history ? 3 : model.watchlistRow }
  private var values: [PlaybackHistoryContext] { shelf == .history ? model.continueWatching.entries.map(\.context) : model.watchlist.entries }
  private func open(_ id: String) { if shelf == .history { model.continueWatching.open(id) } else { model.watchlist.open(id) } }
  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text(shelf == .history ? "继续观看" : "待看片单").font(.system(size: 25, weight: .bold)).tracking(-0.5)
        Spacer()
        Text(L("菜单键管理")).font(.system(size: 14)).foregroundStyle(.secondary)
      }
      ScrollViewReader { shelfScroll in
        ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(alignment: .top, spacing: 24) {
            ForEach(Array(values.enumerated()), id: \.element.id) { index, context in
              let progress = shelf == .history ? model.continueWatching.entries.first(where: { $0.id == context.id })?.progress : nil
              TVButton(selected: model.focus.row == row && model.focus.column == index,
                action: { open(context.id) }, hover: { model.focus.select(row: row, column: index) }) {
                VStack(alignment: .leading, spacing: 10) {
                  Artwork(address: model.savedContentPoster(context, capability: shelf.capability)).frame(width: 260, height: 146)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                  if let progress, let duration = progress.duration {
                    ProgressView(value: min(progress.position, duration), total: duration).tint(.white)
                  }
                  Text(context.title).font(.system(size: 17, weight: .semibold)).lineLimit(2).frame(height: 44, alignment: .topLeading)
                  Text(context.sourceTitle + (progress.map { " · " + clock($0.position) } ?? ""))
                    .font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
                }.padding(6).frame(width: 272)
              }.id(context.id)
            }
          }.padding(.vertical, 8).padding(.horizontal, 6)
        }.padding(.horizontal, -6)
          .onChange(of: model.focus.column) { _, column in
            if model.focus.row == row, values.indices.contains(column) { shelfScroll.scrollTo(values[column].id, anchor: .center) }
          }
          .onChange(of: model.focus.row) { _, selectedRow in
            if selectedRow == row, values.indices.contains(model.focus.column) { shelfScroll.scrollTo(values[model.focus.column].id, anchor: .center) }
          }
      }
    }.id("row-\(row)")
  }
  private func clock(_ value: Double) -> String {
    guard value.isFinite, value >= 0, value < Double(Int.max) else { return "--:--" }
    let seconds = Int(value)
    return seconds >= 3600 ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
      : String(format: "%02d:%02d", seconds / 60, seconds % 60)
  }
}
struct SavedContentMenu: View {
  let title: String
  let scope: String
  let removeTitle: String
  @Binding var selection: Int
  let activate: () -> Void
  var body: some View {
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 24) {
        Text(title).font(.system(size: 28, weight: .bold)).lineLimit(2)
        Text(scope).font(.system(size: 17)).foregroundStyle(.secondary)
        HStack(spacing: 18) {
          ForEach(Array(["打开", removeTitle, "返回"].enumerated()), id: \.offset) { index, label in
            TVButton(selected: selection == index, action: { selection = index; activate() },
              hover: { selection = index }) { Text(label).font(.system(size: 19)).padding(20) }
          }
        }
      }.padding(40).frame(maxWidth: 850).tvPopupSurface(radius: 28)
    }
  }
}
struct ContinueWatchingMenu: View {
  @ObservedObject var controller: ContinueWatchingController
  var body: some View {
    SavedContentMenu(title: controller.entries.first(where: { $0.id == controller.menuID })?.context.title ?? "继续观看",
      scope: "移除只影响这排内容；再次观看后会重新出现。影片和播放进度会保留。",
      removeTitle: "从继续观看移除", selection: $controller.menuIndex, activate: controller.activateMenu)
  }
}
struct WatchlistMenu: View {
  @ObservedObject var controller: WatchlistController
  var body: some View {
    SavedContentMenu(title: controller.entries.first(where: { $0.id == controller.menuID })?.title ?? "待看片单",
      scope: "从待看片单移除。影片、继续观看和播放进度都会保留。",
      removeTitle: "从待看片单移除", selection: $controller.menuIndex, activate: controller.activateMenu)
  }
}

struct ContinueWatchingRecoveryPanel: View {
  @ObservedObject var controller: ContinueWatchingController
  var body: some View {
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 24) {
        Text(controller.recoveryReview == nil ? "观看记录" : "备份并重建观看列表？").font(.system(size: 30, weight: .bold))
        Text(controller.recoveryMessage).font(.system(size: 21)).lineSpacing(8)
        if let review = controller.recoveryReview {
          Text(L("先保存原始数据备份，再清空继续观看卡片。影片、播放位置、账号和内容来源都会保留。"))
            .font(.system(size: 18)).foregroundStyle(.secondary).lineSpacing(8)
          Text(L("备份大小：\(review.byteCount) 字节")).font(.system(size: 15)).foregroundStyle(.secondary)
        }
        if controller.recoveryBusy { ProgressView().controlSize(.large) }
        else {
          HStack(spacing: 20) {
            TVButton(selected: controller.recoverySelection == 0,
              action: { controller.recoverySelection = 0; controller.activateRecovery() }, hover: { controller.recoverySelection = 0 }) {
              Text(controller.recoveryReview == nil ? "返回" : "保留并返回").font(.system(size: 20)).padding(22)
            }
            if controller.recoveryReview != nil {
              TVButton(selected: controller.recoverySelection == 1,
                action: { controller.recoverySelection = 1; controller.activateRecovery() }, hover: { controller.recoverySelection = 1 }) {
                Text(L("备份并重建")).font(.system(size: 20, weight: .semibold)).padding(22)
              }
            }
          }
        }
      }.padding(44).frame(maxWidth: 880).tvPopupSurface(radius: 28)
    }
  }
}

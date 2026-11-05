import SwiftUI
import MTVCore

struct LibraryOverviewPanel: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject var controller: LibraryOverviewController
  let refresh: () -> Void
  let search: () -> Void
  let clear: () -> Void
  var body: some View {
    GeometryReader { geometry in
      let width = max(110, (geometry.size.width - 160 - 5 * 24) / 6)
      ZStack {
        TVPalette.surface.ignoresSafeArea()
        ScrollViewReader { scroll in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
              Text("全部资料库").font(.system(size: 48, weight: .bold)).tracking(-1.5)
              HStack(spacing: 20) {
                TVButton(selected: controller.row == 0 && controller.column == 0, action: { controller.close() },
                  hover: { controller.row = 0; controller.column = 0 }) {
                  Label("返回", systemImage: "chevron.left").font(.title3).padding(20)
                }
                TVButton(selected: controller.row == 0 && controller.column == 1, action: refresh,
                  hover: { controller.row = 0; controller.column = 1 }) {
                  Label(L("刷新总览"), systemImage: "arrow.clockwise").font(.title3).padding(20)
                }
                TVButton(selected: controller.row == 0 && controller.column == 2, action: search,
                  hover: { controller.row = 0; controller.column = 2 }) {
                  Label(controller.query.isEmpty ? "搜索全部来源" : controller.query, systemImage: "magnifyingglass")
                    .font(.title3).lineLimit(1).frame(maxWidth: 360).padding(20)
                }
                TVButton(selected: controller.row == 0 && controller.column == 3, action: clear,
                  hover: { controller.row = 0; controller.column = 3 }) {
                  Label(L("清除搜索"), systemImage: "xmark.circle").font(.title3).padding(20)
                }
              }.id(0)
              if controller.loading { ProgressView("正在读取资料库…") }
              if !controller.message.isEmpty { Text(controller.message).foregroundStyle(.secondary) }
              ForEach(Array(controller.rows.enumerated()).dropFirst(), id: \.offset) { index, row in
                switch row {
                case .actions: EmptyView()
                case .source(let section):
                  let entry = controller.sections[section]
                  TVButton(selected: controller.row == index,
                    action: { controller.row = index; controller.column = 0; controller.activate() },
                    hover: { controller.row = index; controller.column = 0 }) {
                    HStack {
                      VStack(alignment: .leading, spacing: 8) {
                        Text(entry.source.title).font(.system(size: 28, weight: .semibold))
                        Text((controller.query.isEmpty ? "\(entry.fileCount) 个影片文件" : "\(entry.matchingCount) 项匹配") + " · \(entry.message)").font(.system(size: 16)).foregroundStyle(.secondary)
                      }
                      Spacer()
                      Label(L("打开来源"), systemImage: "chevron.right").font(.system(size: 17))
                    }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                  }.id(index)
                case .cards(let section, let range):
                  HStack(alignment: .top, spacing: 24) {
                    ForEach(Array(range.enumerated()), id: \.element) { column, cardIndex in
                      let card = controller.sections[section].cards[cardIndex]
                      TVButton(selected: controller.row == index && controller.column == column,
                        action: { controller.row = index; controller.column = column; controller.activate() },
                        hover: { controller.row = index; controller.column = column }) {
                        VStack(alignment: .leading, spacing: 12) {
                          Artwork(address: card.poster).frame(width: width, height: width * 1.5)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                            .overlay(alignment: .bottomLeading) {
                              if card.offline { Label(controller.sections[section].source.smbProfileID == nil ? "片源离线" : "NAS 缓存", systemImage: "externaldrive").font(.caption).padding(8).background(.black.opacity(0.75), in: Capsule()).padding(8) }
                            }
                            .overlay(alignment: .topLeading) {
                              if card.metadataReadFailed { Text("资料待更新").font(.caption).padding(8).background(.black.opacity(0.8), in: Capsule()).padding(8) }
                            }
                          Text(card.title).font(.system(size: 18, weight: .semibold)).lineLimit(2).padding(.horizontal, 8)
                          Text(card.collection ? "系列" : card.subtitle).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1).padding(.horizontal, 8).padding(.bottom, 8)
                        }.frame(width: width, alignment: .leading)
                      }
                    }
                    Spacer(minLength: 0)
                  }.id(index)
                }
              }
            }.padding(.horizontal, 64).padding(.vertical, 44)
          }.onChange(of: controller.row) { _, row in withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { scroll.scrollTo(row, anchor: .center) } }
            .onAppear { scroll.scrollTo(controller.row, anchor: .center) }
        }.allowsHitTesting(!controller.versionsPresented)
        if controller.versionsPresented {
          TVPopupBackdrop()
          LibraryVersionPicker(controller: controller)
            .frame(width: min(1100, geometry.size.width - 100), height: min(680, geometry.size.height - 80))
        }
      }
    }
  }
}

private struct LibraryVersionPicker: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject var controller: LibraryOverviewController
  var body: some View {
    HStack(alignment: .top, spacing: 36) {
      let card = controller.versions.indices.contains(controller.versionIndex) ? controller.versions[controller.versionIndex].card : controller.versions.first?.card
      Artwork(address: card?.poster).frame(width: 210, height: 315)
        .clipShape(RoundedRectangle(cornerRadius: 20)).padding(.top, 10)
      VStack(alignment: .leading, spacing: 16) {
        Text(controller.versionsTitle).font(.system(size: 34, weight: .bold)).tracking(-0.6).lineLimit(2)
        Text(L("选择影片版本")).font(.system(size: 22, weight: .semibold))
        if controller.versionsLoading { ProgressView("正在核对已保存的影片资料…") }
        if !controller.versionsMessage.isEmpty {
          Text(controller.versionsMessage).font(.system(size: 15)).foregroundStyle(.orange).lineLimit(4)
        }
        ScrollViewReader { scroll in
          ScrollView {
            VStack(spacing: 12) {
              ForEach(Array(controller.versions.enumerated()), id: \.element.id) { index, entry in
                TVButton(selected: controller.versionIndex == index,
                  action: { controller.versionIndex = index; controller.activate() },
                  hover: { controller.versionIndex = index }) {
                  VStack(alignment: .leading, spacing: 8) {
                    HStack {
                      Text(entry.source.title).font(.system(size: 21, weight: .semibold)).lineLimit(1)
                      Spacer()
                      if entry.source.smbProfileID != nil { Text(L("NAS 缓存")).font(.system(size: 13)).foregroundStyle(.secondary) }
                      else if entry.card.offline { Text("片源离线").font(.system(size: 13)).foregroundStyle(.secondary) }
                      Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold))
                    }
                    Text(entry.card.filename ?? entry.card.title).font(.system(size: 17)).lineLimit(2).truncationMode(.middle)
                    if !entry.card.subtitle.isEmpty { Text(entry.card.subtitle).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1) }
                  }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }.id(index)
              }
              TVButton(selected: controller.versionsLoading || controller.versionIndex == controller.versions.count,
                action: { controller.dismissVersions() }, hover: { controller.versionIndex = controller.versions.count }) {
                Label(L("返回影片列表"), systemImage: "chevron.left").font(.system(size: 18, weight: .medium))
                  .padding(20).frame(maxWidth: .infinity, alignment: .leading)
              }.id(controller.versions.count)
            }.padding(14)
          }.scrollIndicators(.hidden)
            .onChange(of: controller.versionIndex) { _, index in
              withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { scroll.scrollTo(index, anchor: .center) }
            }
            .onChange(of: controller.versionsLoading) { _, loading in
              if !loading { scroll.scrollTo(controller.versionIndex, anchor: .center) }
            }
        }
      }
    }.padding(36).tvPopupSurface(radius: 30)
      .overlay(RoundedRectangle(cornerRadius: 30).stroke(.white.opacity(0.08), lineWidth: 1))
  }
}

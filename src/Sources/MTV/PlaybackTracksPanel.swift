import SwiftUI
import MTVCore

struct PlaybackTracksPanel: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @ObservedObject var controller: PlaybackTracksController
  var body: some View {
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 20) {
        Text(controller.kind.title).font(.system(size: 34, weight: .bold))
        if controller.loading { ProgressView(L("正在读取轨道…")) }
        if controller.busy { ProgressView(L("正在应用…")) }
        if !controller.message.isEmpty { Text(controller.message).font(.system(size: 16)).foregroundStyle(.orange) }
        ScrollViewReader { scroll in
          ScrollView {
            VStack(spacing: 12) {
              ForEach(Array(controller.options.enumerated()), id: \.element.id) { index, option in
                TVButton(selected: !controller.loading && controller.selection == index,
                  action: { controller.selection = index; controller.activate() },
                  hover: { if !controller.busy { controller.selection = index } }) {
                  HStack(spacing: 20) {
                    Image(systemName: controller.kind == .audio ? "waveform" : "captions.bubble")
                    VStack(alignment: .leading, spacing: 6) {
                      Text(option.title).font(.system(size: 21, weight: .medium)).lineLimit(2)
                      if !option.detail.isEmpty { Text(option.detail).font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    Spacer()
                    if controller.isSelected(option) { Image(systemName: "checkmark").fontWeight(.semibold) }
                  }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }.id(index).disabled(controller.busy)
              }
              TVButton(selected: controller.loading || controller.selection == controller.options.count,
                action: { controller.close() }, hover: { if !controller.busy { controller.selection = controller.options.count } }) {
                Label(L("返回播放"), systemImage: "chevron.left").font(.system(size: 20, weight: .medium))
                  .padding(20).frame(maxWidth: .infinity, alignment: .leading)
              }.id(controller.options.count)
            }.padding(14)
          }.scrollIndicators(.hidden)
            .onChange(of: controller.selection) { _, index in
              withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { scroll.scrollTo(index, anchor: .center) }
            }
            .onChange(of: controller.loading) { _, value in if !value { scroll.scrollTo(controller.selection, anchor: .center) } }
        }
      }.padding(34).frame(width: 740, height: 600)
        .tvPopupSurface(radius: 28)
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.08), lineWidth: 1))
    }
  }
}

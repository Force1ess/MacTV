import AVFoundation
import SwiftUI
import MTVCore

struct VideoPresentationPanel: View {
  @ObservedObject var controller: VideoPresentationController
  var body: some View {
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 28) {
        Text(L("画面与片源")).font(.system(size: 38, weight: .bold)).tracking(-1)
        HStack(alignment: .top, spacing: 40) {
          VStack(alignment: .leading, spacing: 14) {
            if controller.supportsModes {
              ForEach(Array(VideoRangeChoice.allCases.enumerated()), id: \.element) { index, choice in
                TVButton(selected: controller.selection == index,
                  action: { controller.selection = index; controller.activate() },
                  hover: { controller.selection = index }) {
                  VStack(alignment: .leading, spacing: 8) {
                    HStack {
                      Text(choice.title).font(.system(size: 23, weight: .semibold))
                      Spacer()
                      if choice == controller.preference { Image(systemName: "checkmark") }
                    }
                  }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
                }
              }
            }
            TVButton(selected: controller.selection == controller.count - 1,
              action: { controller.close() }, hover: { controller.selection = controller.count - 1 }) {
              Label(L("继续观看"), systemImage: "arrow.uturn.backward").font(.title3).padding(22)
            }
          }.frame(width: 480)
          VStack(alignment: .leading, spacing: 18) {
            Text(L("片源")).font(.system(size: 24, weight: .semibold))
            if let signal = controller.signal {
              Text("\(signal.codec) · \(signal.width) × \(signal.height)").font(.system(size: 21))
              Text(signal.rangeLabel).font(.system(size: 21))
              if let rate = signal.framesPerSecond { Text(String(format: "%.2f 帧/秒", rate)).foregroundStyle(.secondary) }
              if let primaries = signal.primaries { Text(L("色域标记：") + primaries).font(.system(size: 16)).foregroundStyle(.secondary) }
            }
            Text(controller.signalMessage).font(.system(size: 15)).foregroundStyle(.secondary)
            Divider().padding(.vertical, 8)
            Text(L("当前显示")).font(.system(size: 24, weight: .semibold))
            if let display = controller.display {
              Text(display.name).font(.system(size: 21))
              Text(String(format: "动态范围余量：%.2f×（可用上限 %.2f×）", display.currentEDR, display.potentialEDR))
                .font(.system(size: 16)).foregroundStyle(.secondary)
              Text(display.systemHDREligible ? "macOS 报告 HDR 可播放" : "macOS 当前未报告 HDR 可播放")
                .font(.system(size: 17))
            } else { Text(L("没有取得此窗口的显示信息")).foregroundStyle(.secondary) }
          }.frame(maxWidth: .infinity, alignment: .leading)
        }

      }.padding(42).frame(width: 1110, height: 650)
        .tvPopupSurface(radius: 30)
    }.onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in controller.refreshDisplay() }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { _ in controller.refreshDisplay() }
      .onReceive(NotificationCenter.default.publisher(for: AVPlayer.eligibleForHDRPlaybackDidChangeNotification)) { _ in controller.refreshDisplay() }
  }
}

import MTVCore
import SwiftUI

struct SourceSetupPanel: View {
  @ObservedObject var controller: SourceSetupController
  var error: String?
  var body: some View {
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 28) {
        Text(L("影片来源")).font(.system(size: 36, weight: .semibold))
        if let error { Text(error).font(.system(size: 17)).foregroundStyle(.orange).lineLimit(2) }
        HStack(spacing: 22) {
          card(0, title: "影片文件夹", symbol: "folder.fill", color: .blue)
          card(
            1, title: "NAS",
            symbol: "externaldrive.connected.to.line.below.fill", color: .purple)
          card(
            2, title: "先使用应用", symbol: "square.grid.2x2.fill", color: .orange
          )
        }.padding(.vertical, 20)
        HStack {
          Spacer()
          TVButton(
            selected: controller.selection == 3,
            action: {
              controller.selection = 3
              controller.activate()
            },
            hover: { controller.selection = 3 }
          ) {
            Text(L("稍后再说")).font(.system(size: 18, weight: .medium)).padding(18)
          }
        }
      }.padding(46).frame(width: 1100, height: 430)
        .tvPopupSurface(radius: 32)
    }
  }
  private func card(_ index: Int, title: String, symbol: String, color: Color)
    -> some View
  {
    TVButton(
      selected: controller.selection == index,
      action: {
        controller.selection = index
        controller.activate()
      },
      hover: { controller.selection = index }
    ) {
      VStack(alignment: .leading, spacing: 14) {
        Image(systemName: symbol).font(.system(size: 40, weight: .light)).foregroundStyle(color)
          .padding(.bottom, 25)
        Text(LT(title)).font(.system(size: 25, weight: .semibold))
      }.padding(28).frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
        .background(
          LinearGradient(
            colors: [color.opacity(0.12), TVPalette.surface],
            startPoint: .topLeading, endPoint: .bottomTrailing),
          in: RoundedRectangle(cornerRadius: 16))
    }
  }
}

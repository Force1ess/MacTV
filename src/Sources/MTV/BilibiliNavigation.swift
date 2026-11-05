import SwiftUI
import MTVCore

enum BilibiliChannel: String, CaseIterable {
  case popular, ranking, home, dynamic, favorites, watchLater
  var title: String {
    switch self {
    case .popular: "热门"
    case .ranking: "排行榜"
    case .home: "首页"
    case .dynamic: "动态"
    case .favorites: "收藏夹"
    case .watchLater: "稍后再看"
    }
  }
}

struct BilibiliNavigation: View {
  @ObservedObject var model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    HStack(spacing: 12) {
      Spacer()
      ForEach(Array(BilibiliChannel.allCases.enumerated()), id: \.offset) { index, channel in
        let focused = model.focus.row == model.bilibiliChannelRow && model.focus.column == index
        Button { model.selectBilibiliChannel(at: index) } label: {
          Text(LT(channel.title)).font(.system(size: 22, weight: .semibold))
            .foregroundStyle(focused ? .black : .white.opacity(model.bilibiliChannel == channel ? 1 : 0.55))
            .frame(width: 126, height: 54)
            .background(focused ? .white : .white.opacity(model.bilibiliChannel == channel ? 0.12 : 0), in: Capsule())
            .animation(reduceMotion ? nil : .timingCurve(0.22, 0.8, 0.25, 1, duration: 0.18), value: focused)
        }.buttonStyle(.plain).tvPointerFocus { model.selectBilibiliChannel(at: index) }
      }
      Spacer()
    }.id("row-\(model.bilibiliChannelRow)")
  }
}

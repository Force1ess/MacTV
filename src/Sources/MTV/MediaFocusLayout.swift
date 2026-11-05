import SwiftUI
import MTVCore

struct MediaTitleAnchorKey: PreferenceKey {
  static var defaultValue: [String: Anchor<CGRect>] { [:] }
  static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
    value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
  }
}

struct MediaFocusLayout: Equatable {
  let itemID: String
  let row: Int
  let column: Int
  let title: CGRect
  let viewport: CGSize
  var titleFullyVisible: Bool {
    title.width > 0 && title.height > 0 && title.minX >= -1 && title.minY >= -1
      && title.maxX <= viewport.width + 1 && title.maxY <= viewport.height + 1
  }
}

extension AppModel {
  var focusedMediaItem: MediaItem? {
    guard [.home, .library, .bilibili].contains(section), focus.row >= mediaFocusOffset else { return nil }
    let index = (focus.row - mediaFocusOffset) * gridColumns + focus.column
    return visibleItems.indices.contains(index) ? visibleItems[index] : nil
  }
}

/// Resolve only the selected title in the scroll viewport. Non-published
/// observations avoid invalidating layout or writing an event on every frame.
struct MediaFocusObserver: View {
  @ObservedObject var model: AppModel
  let anchors: [String: Anchor<CGRect>]
  var body: some View {
    if let item = model.focusedMediaItem, let anchor = anchors[item.id] {
      GeometryReader { geometry in
        let observation = MediaFocusLayout(itemID: item.id, row: model.focus.row, column: model.focus.column,
          title: geometry[anchor], viewport: geometry.size)
        Color.clear.onAppear { model.mediaFocusLayout = observation }
          .onChange(of: observation) { _, value in model.mediaFocusLayout = value }
      }
    }
  }
}

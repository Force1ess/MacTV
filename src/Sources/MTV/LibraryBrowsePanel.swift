import SwiftUI
import MTVCore

struct LibraryBrowsePanel: View {
  @ObservedObject var controller: LibraryBrowseController
  var body: some View {
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 16) {
        Text(L("分类与排序")).font(.system(size: 36, weight: .bold))
        Text(L("内容")).font(.system(size: 20, weight: .semibold))
        HStack(spacing: 16) {
          ForEach(Array(LibraryBrowseKind.allCases.enumerated()), id: \.element) { column, kind in
            TVButton(selected: controller.row == 0 && controller.column == column,
              action: { controller.row = 0; controller.column = column; controller.activate() }, hover: { controller.row = 0; controller.column = column }) {
              HStack(spacing: 14) {
                Text(kind.title)
                if controller.draft.kind == kind { Image(systemName: "checkmark") }
              }.font(.system(size: 21, weight: .medium)).frame(maxWidth: .infinity, minHeight: 56)
            }
          }
        }
        Text(L("顺序")).font(.system(size: 20, weight: .semibold))
        HStack(spacing: 16) {
          ForEach(Array(LibraryBrowseOrder.allCases.enumerated()), id: \.element) { column, order in
            TVButton(selected: controller.row == 1 && controller.column == column,
              action: { controller.row = 1; controller.column = column; controller.activate() }, hover: { controller.row = 1; controller.column = column }) {
              HStack(spacing: 12) {
                Text(order.title)
                if controller.draft.order == order { Image(systemName: "checkmark") }
              }.font(.system(size: 18, weight: .medium)).frame(maxWidth: .infinity, minHeight: 56)
            }
          }
        }
      }.padding(30).frame(width: 850)
        .tvPopupSurface(radius: 30)
    }
  }
}

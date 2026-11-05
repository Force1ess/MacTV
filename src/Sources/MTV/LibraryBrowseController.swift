import Foundation
import MTVCore

@MainActor final class LibraryBrowseController: ObservableObject {
  @Published private(set) var isPresented = false
  @Published var draft = LibraryBrowseOptions()
  @Published var row = 0
  @Published var column = 0
  var onApply: ((LibraryBrowseOptions) -> Void)?
  func present(_ value: LibraryBrowseOptions) {
    TVPointerFocus.remoteInput(); draft = value; isPresented = true
    row = 0; column = LibraryBrowseKind.allCases.firstIndex(of: value.kind) ?? 0
  }
  func close() { isPresented = false }
  func move(dx: Int, dy: Int) {
    row = min(max(0, row + dy), 1)
    let count = row == 0 ? LibraryBrowseKind.allCases.count : LibraryBrowseOrder.allCases.count
    column = min(max(0, column + dx), count - 1)
  }
  func activate() {
    switch row {
    case 0: guard LibraryBrowseKind.allCases.indices.contains(column) else { return }; draft.kind = LibraryBrowseKind.allCases[column]
    case 1: guard LibraryBrowseOrder.allCases.indices.contains(column) else { return }; draft.order = LibraryBrowseOrder.allCases[column]
    default: return
    }
    onApply?(draft)
    close()
  }
}

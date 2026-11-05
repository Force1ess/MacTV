import Foundation

enum SourceSetupChoice { case local, nas, applications, later }
@MainActor final class SourceSetupController: ObservableObject {
  @Published private(set) var isPresented = false
  @Published var selection = 0
  var onChoose: ((SourceSetupChoice) -> Void)?
  private var lastCard = 0
  func present() {
    TVPointerFocus.remoteInput()
    selection = 0
    lastCard = 0
    isPresented = true
  }
  func close() { isPresented = false }
  func move(_ step: Int) { selection = min(3, max(0, selection + step)) }
  func moveVertical(_ step: Int) {
    if step > 0 {
      if selection < 3 { lastCard = selection }
      selection = 3
    } else if selection == 3 {
      selection = lastCard
    }
  }
  func activate() {
    let choices: [SourceSetupChoice] = [.local, .nas, .applications, .later]
    guard choices.indices.contains(selection) else { return }
    isPresented = false
    onChoose?(choices[selection])
  }
}

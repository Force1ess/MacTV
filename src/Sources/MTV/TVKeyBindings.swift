import Foundation

enum TVKeyBindings {
  static let guide: [(action: String, keys: String)] = [
    ("移动选择", "↑ ↓ ← →"), ("确定 / 播放", "Enter / 遥控器确定"),
    ("返回上一级", "Esc / Backspace"), ("更多操作", "C / 遥控器菜单")
  ]
  /// Physical Backspace and Escape always dismiss one level, including text
  /// entry. Deleting text remains available on the on-screen keyboard.
  static func navigationAction(keyCode: UInt16, keyboardVisible: Bool) -> InputAction? {
    switch keyCode {
    case 123: return .left
    case 124: return .right
    case 125: return .down
    case 126: return .up
    case 36, 76: return .select
    case 51, 53: return .back
    case 117: return keyboardVisible ? .delete : .back
    default: return nil
    }
  }
}

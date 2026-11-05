import MTVCore
import AppKit
import SwiftUI

enum TVAppearance: String, CaseIterable {
  case system, dark, light
  var title: String { switch self { case .system: return "跟随系统"; case .dark: return "深色"; case .light: return "浅色" } }
  var scheme: ColorScheme? { switch self { case .system: return nil; case .dark: return .dark; case .light: return .light } }
}

enum TVPalette {
  static let background = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
      ? NSColor(white: 0.025, alpha: 1) : NSColor(white: 0.95, alpha: 1)
  })
  static let surface = Color(nsColor: .controlBackgroundColor)
}

private struct TVGlassStyle: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.tvGlassEnabled) private var enabled
  let radius: CGFloat
  @ViewBuilder func body(content: Content) -> some View {
    if #available(macOS 26, *), enabled, !reduceTransparency {
      content.background(TVPalette.surface.opacity(0.82), in: RoundedRectangle(cornerRadius: radius))
        .glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius))
    } else {
      content.background(TVPalette.surface, in: RoundedRectangle(cornerRadius: radius))
        .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(.primary.opacity(0.08)))
    }
  }
}
private struct TVGlassKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
  var tvGlassEnabled: Bool { get { self[TVGlassKey.self] } set { self[TVGlassKey.self] = newValue } }
}
extension View { func tvGlass(radius: CGFloat = 28) -> some View { modifier(TVGlassStyle(radius: radius)) } }

struct TVPopupBackdrop: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  var body: some View {
    Color.black.opacity(reduceTransparency ? 0.55 : 0.24).ignoresSafeArea()
  }
}

private struct TVPopupSurface: ViewModifier {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  @Environment(\.tvGlassEnabled) private var glassEnabled
  let radius: CGFloat
  @ViewBuilder func body(content: Content) -> some View {
    let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
    if !glassEnabled || reduceTransparency {
      content.background(TVPalette.surface, in: shape)
    } else if #available(macOS 26, *) {
      content.background(TVPalette.surface.opacity(0.16), in: shape)
        .glassEffect(.regular, in: shape)
    } else {
      content.background(.regularMaterial, in: shape)
        .overlay { shape.strokeBorder(.primary.opacity(0.1)).allowsHitTesting(false) }
        .shadow(color: .black.opacity(0.18), radius: 22, y: 10)
    }
  }
}

extension View {
  func tvPopupSurface(radius: CGFloat = 28) -> some View { modifier(TVPopupSurface(radius: radius)) }
}

extension AppModel {
  func setAppearance(_ value: TVAppearance) {
    appearance = value
    if !CommandLine.arguments.contains("--ui-smoke") { UserDefaults.standard.set(value.rawValue, forKey: "mtv.appearance") }
  }
  func setGlass(_ enabled: Bool) {
    glassEnabled = enabled
    if !CommandLine.arguments.contains("--ui-smoke") { UserDefaults.standard.set(enabled, forKey: "mtv.glass") }
  }
  func handleAppearance(_ action: InputAction) {
    switch action {
    case .up, .left: appearanceSelection = max(0, appearanceSelection - 1)
    case .down, .right: appearanceSelection = min(5, appearanceSelection + 1)
    case .select:
      if appearanceSelection < 3 { setAppearance(TVAppearance.allCases[appearanceSelection]) }
      else if appearanceSelection < 5 { setGlass(appearanceSelection == 3) }
      else { appearanceVisible = false }
    default: break
    }
  }
}

struct TVAppearancePanel: View {
  @ObservedObject var model: AppModel
  var body: some View {
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 14) {
        Text("外观").font(.system(size: 34, weight: .bold))
        ForEach(0..<6, id: \.self) { index in
          TVButton(selected: model.appearanceSelection == index,
            action: { model.appearanceSelection = index; model.handleAppearance(.select) },
            hover: { model.appearanceSelection = index }) {
            HStack {
              Text(index < 3 ? TVAppearance.allCases[index].title : ["玻璃效果", "简洁效果", "返回设置"][index - 3])
              Spacer()
              if (index < 3 && TVAppearance.allCases[index] == model.appearance)
                || (index == 3 && model.glassEnabled) || (index == 4 && !model.glassEnabled) { Image(systemName: "checkmark") }
            }.font(.system(size: 21, weight: .medium)).padding(17)
          }
        }
      }.padding(32).frame(width: 700).tvPopupSurface()
    }
  }
}

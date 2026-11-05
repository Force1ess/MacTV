import MTVCore
import SwiftUI

enum TVNavigationTab: String, CaseIterable {
  case home, library, bilibili, quark, extensions, settings
  static let defaults: [Self] = [.home, .library, .bilibili, .extensions, .settings]
  static let customizable: [Self] = [.library, .bilibili, .quark, .extensions]
  var title: String {
    switch self {
    case .home: L("首页")
    case .library: L("影片")
    case .bilibili: L("哔哩哔哩")
    case .quark: L("夸克网盘")
    case .extensions: L("应用")
    case .settings: L("设置")
    }
  }
  static func normalized(_ values: [String]) -> [Self] {
    let selected = Set(values.compactMap(Self.init(rawValue:)))
    return allCases.filter { $0 == .home || $0 == .settings || selected.contains($0) }
  }
  static func load() -> [Self] {
    guard !CommandLine.arguments.contains("--ui-smoke"),
      let saved = UserDefaults.standard.stringArray(forKey: "mtv.navigation.tabs") else { return defaults }
    return normalized(saved)
  }
}

extension AppModel {
  var navigationItemCount: Int { visibleNavigationTabs.count }
  var visibleNavigationTabs: [TVNavigationTab] {
    navigationTabs.filter { tab in
      if tab == .quark { return plugins.contains { $0.id == "mtv.quark" && $0.isAvailable } }
      return true
    }
  }
  var activeNavigationTab: TVNavigationTab {
    switch section {
    case .home: .home
    case .library: .library
    case .settings: .settings
    case .extensions: .extensions
    case .bilibili: activePlugin?.id == "mtv.bilibili" ? .bilibili : activePlugin?.id == "mtv.quark" ? .quark : .extensions
    }
  }
  var navigationTabIndex: Int {
    visibleNavigationTabs.firstIndex(of: activeNavigationTab)
      ?? visibleNavigationTabs.firstIndex(of: .extensions) ?? 0
  }
  func setNavigationTab(_ tab: TVNavigationTab, enabled: Bool) {
    guard TVNavigationTab.customizable.contains(tab) else { return }
    let values = enabled ? navigationTabs + [tab] : navigationTabs.filter { $0 != tab }
    navigationTabs = TVNavigationTab.normalized(values.map(\.rawValue))
    if !CommandLine.arguments.contains("--ui-smoke") {
      UserDefaults.standard.set(navigationTabs.map(\.rawValue), forKey: "mtv.navigation.tabs")
    }
    rebuildFocus()
  }
  func handleNavigationCustomization(_ action: InputAction) {
    switch action {
    case .up, .left: navigationCustomizationIndex = max(0, navigationCustomizationIndex - 1)
    case .down, .right: navigationCustomizationIndex = min(TVNavigationTab.customizable.count, navigationCustomizationIndex + 1)
    case .select:
      guard TVNavigationTab.customizable.indices.contains(navigationCustomizationIndex) else {
        navigationCustomizationVisible = false; return
      }
      let tab = TVNavigationTab.customizable[navigationCustomizationIndex]
      setNavigationTab(tab, enabled: !navigationTabs.contains(tab))
    case .home: navigationCustomizationVisible = false; navigate(.home)
    default: break
    }
  }
}

struct TVNavigationPanel: View {
  @ObservedObject var model: AppModel
  var body: some View {
    TVDialog(title: "顶部导航", symbol: "rectangle.topthird.inset.filled") {
      VStack(spacing: 10) {
        ForEach(Array(TVNavigationTab.customizable.enumerated()), id: \.element) { index, tab in
          TVButton(selected: model.navigationCustomizationIndex == index,
            action: { model.navigationCustomizationIndex = index; model.handleNavigationCustomization(.select) },
            hover: { model.navigationCustomizationIndex = index }) {
            HStack {
              Text(tab.title)
              Spacer()
              Image(systemName: model.navigationTabs.contains(tab) ? "checkmark.circle.fill" : "circle")
            }.font(.system(size: 22, weight: .medium)).padding(18)
          }
        }
        TVButton(selected: model.navigationCustomizationIndex == TVNavigationTab.customizable.count,
          action: { model.navigationCustomizationVisible = false },
          hover: { model.navigationCustomizationIndex = TVNavigationTab.customizable.count }) {
          Text(L("完成")).font(.system(size: 22, weight: .medium)).padding(18).frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }
}

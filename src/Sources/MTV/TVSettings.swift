import MTVCore
import SwiftUI

enum TVSetting: Int, CaseIterable {
  case sources, addFolder, nas, scan, engine, audio, metadata, fullscreen, accounts, history, plugins, about, appearance, navigation, information
  var title: String { LT(["影片来源", "添加文件夹", "连接 NAS", "更新影片库", "播放器", "声音输出", "影片识别", "全屏显示", "登录与连接", "观看记录", "管理应用", "使用引导", "外观", "顶部导航", "About MacTV"][rawValue]) }
  var subtitle: String { LT([
    "管理影片文件夹与 NAS 共享。",
    "选择这台 Mac 或外置硬盘中的影片文件夹。",
    "连接家庭网络中的 NAS 共享。",
    "加入新影片，更新海报墙与目录。",
    "自动选择适合影片的播放器。",
    "选择电视、耳机或扬声器，也可以跟随系统。",
    "查找影片名称、海报与简介。",
    "在电视全屏与桌面窗口之间切换。",
    "管理哔哩哔哩与夸克网盘的登录。",
    "查看播放记录，继续上次观看。",
    "安装、更新和管理应用与插件来源。",
    "重新了解片库、登录和遥控操作。",
    "选择深色、浅色或跟随系统，调整玻璃效果。",
    "选择顶部常用入口并调整显示顺序。",
    "Version, film information providers and open-source licenses."
  ][rawValue]) }
  var symbol: String { ["rectangle.stack", "folder.badge.plus", "externaldrive.connected.to.line.below", "arrow.clockwise", "play.rectangle", "speaker.wave.2", "sparkles", "arrow.up.left.and.arrow.down.right", "person.crop.circle", "clock", "square.grid.2x2", "questionmark.circle", "circle.lefthalf.filled", "rectangle.topthird.inset.filled", "info.circle"][rawValue] }
  static let groupTitles = ["影音控制", "通用设置", "应用设置"]
  static let groups: [[Self]] = [
    [.sources, .scan, .audio],
    [.appearance, .fullscreen, .about, .information],
    [.accounts, .plugins, .navigation],
  ]
  var row: Int { Self.groups.firstIndex { $0.contains(self) }.map { $0 + 1 } ?? 1 }
  var column: Int { Self.groups[row - 1].firstIndex(of: self) ?? 0 }
  static func visibleSetting(row: Int, column: Int) -> Self? {
    guard groups.indices.contains(row - 1), groups[row - 1].indices.contains(column) else { return nil }
    return groups[row - 1][column]
  }
}

struct TVSettings: View {
  @ObservedObject var model: AppModel
  private let groups = TVSetting.groupTitles
  private let symbols = ["play.rectangle", "gearshape", "square.grid.2x2"]
  private var group: Int { model.settingsGroup }
  private var items: [TVSetting] { TVSetting.groups[group - 1] }
  var body: some View {
    HStack(alignment: .top, spacing: 44) {
      VStack(alignment: .leading, spacing: 14) {
        ForEach(1...TVSetting.groups.count, id: \.self) { index in
          TVButton(selected: model.focus.row > 0 && model.settingsSidebarFocus && group == index,
            action: { chooseGroup(index); model.settingsSidebarFocus = false }, hover: { chooseGroup(index) }) {
            HStack(spacing: 15) {
              Image(systemName: symbols[index - 1]).frame(width: 28)
              Text(LT(groups[index - 1])); Spacer()
              if index == group { Image(systemName: "chevron.right").font(.system(size: 13, weight: .bold)) }
            }.font(.system(size: 22, weight: .medium)).padding(22)
              .background(.primary.opacity(group == index ? 0.06 : 0), in: RoundedRectangle(cornerRadius: 16))
          }
        }
        Spacer(minLength: 12)
      }.frame(width: 300)
      VStack(alignment: .leading, spacing: 20) {
        Text(LT(groups[group - 1])).font(.system(size: 29, weight: .bold)).padding(.bottom, 5)
        VStack(spacing: 2) {
          ForEach(items, id: \.rawValue) { setting in
            TVButton(selected: model.focus.row > 0 && !model.settingsSidebarFocus && model.focus.column == setting.column,
              action: { model.performSetting(setting) }, hover: {
                model.settingsSidebarFocus = false; model.focus.select(row: setting.row, column: setting.column)
              }) {
              HStack(spacing: 17) {
                Image(systemName: setting.symbol).font(.system(size: 22)).frame(width: 32)
                Text(setting.title).font(.system(size: 23, weight: .medium))
                Spacer()
                Text(value(setting)).font(.system(size: 18)).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 14, weight: .semibold)).foregroundStyle(.tertiary)
              }.padding(.horizontal, 24).frame(height: 76)
            }
            if setting != items.last { Divider().padding(.horizontal, 24) }
          }
        }.padding(8).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 24))
        if let error = model.sourceError { Text(error).font(.system(size: 16)).foregroundStyle(.orange) }
      }.frame(maxWidth: .infinity)
    }.frame(minHeight: 440).id("row-\(group)")
  }
  private func chooseGroup(_ index: Int) {
    model.settingsGroup = index; model.settingsSidebarFocus = true; model.focus.select(row: index, column: 0)
  }
  private func value(_ setting: TVSetting) -> String {
    switch setting {
    case .sources: return model.hasLibrarySource ? URL(fileURLWithPath: model.mediaSourceDisplay).lastPathComponent : "尚未添加"
    case .engine: return model.preferredEngine.title
    case .appearance: return model.appearance.title
    case .audio: return "选择设备"
    default: return ""
    }
  }
}

struct TVAccounts: View {
  @ObservedObject var model: AppModel
  var body: some View {
    let plugins = model.plugins.filter { $0.manifest.authentication != nil }
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 24) {
        Text(L("登录与连接")).font(.system(size: 34, weight: .bold))
        ForEach(Array(plugins.enumerated()), id: \.element.id) { index, plugin in
          TVButton(selected: model.accountSettingsIndex == index,
            action: { model.showLogin(plugin) }, hover: { model.accountSettingsIndex = index }) {
            HStack(spacing: 20) {
              if let icon = BrandIcon.image(plugin.id) { Image(nsImage: icon).resizable().scaledToFit().frame(width: 52, height: 52).clipShape(RoundedRectangle(cornerRadius: 12)) }
              Text(plugin.title).font(.system(size: 23, weight: .semibold))
              Spacer()
              Text(model.login.accountTitle(for: plugin)).font(.system(size: 18)).foregroundStyle(.secondary)
              Image(systemName: "chevron.right")
            }.padding(24).frame(width: 650)
          }
        }
        TVButton(selected: model.accountSettingsIndex == plugins.count,
          action: { model.accountSettingsVisible = false }, hover: { model.accountSettingsIndex = plugins.count }) {
          Text(L("返回设置")).font(.system(size: 20)).padding(22).frame(width: 650, alignment: .leading)
        }
      }.padding(36).tvPopupSurface(radius: 28)
    }
  }
}

import SwiftUI
import MTVCore

struct PluginManagerPanel: View {
  @ObservedObject var controller: PluginManagerController
  var body: some View {
    GeometryReader { geometry in
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 20) {
        Text(controller.title).font(.system(size: 38, weight: .bold))
        if !controller.summary.isEmpty {
          Text(controller.summary).font(.system(size: 18)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
        if !controller.message.isEmpty { Text(LT(controller.message)).foregroundStyle(.orange).lineLimit(3) }
        if controller.loading { ProgressView(L("正在处理…")) }
        ScrollViewReader { scroll in
          ScrollView {
            LazyVStack(spacing: 12) {
              ForEach(Array(controller.controls.enumerated()), id: \.offset) { index, control in
                TVButton(selected: controller.selection == index,
                  action: { controller.selection = index; controller.activate() },
                  hover: { controller.selection = index }) {
                  Text(label(control)).font(.system(size: 20, weight: .medium)).multilineTextAlignment(.leading)
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                }.id(index)
              }
            }.padding(10)
          }.onChange(of: controller.selection) { _, row in scroll.scrollTo(row, anchor: .center) }
        }
      }.padding(32).frame(width: min(1040, max(320, geometry.size.width - 64)),
        height: min(660, max(280, geometry.size.height - 64)))
        .tvPopupSurface(radius: 32)
    }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
  private func label(_ control: PluginManagerController.Control) -> String {
    switch control {
    case .back: return L("返回")
    case .add: return L("从文件夹安装插件…")
    case .sources: return L("Plugin Sources")
    case .addSource: return L("Add Git Repository")
    case .openSource(let source): return LT(source.name)+" · "+(source.enabled ? L("Enabled"):L("Disabled"))
    case .toggleSource(let source): return source.enabled ? L("Disable Source"):L("Enable Source")
    case .removeSource: return L("Remove Source (Keep Installed Plugins)")
    case .sourceReference: return L("Change Git Branch or Tag")
    case .refreshSource: return L("Refresh Plugin Catalog")
    case .bundledCatalog: return L("Browse Bundled Catalog (Offline)")
    case .installEntry(let entry):
      let installed=controller.packages.first(where:{$0.id==entry.id})
      return entry.displayName+" · "+entry.version+(installed.map { " · "+L("Installed: \($0.manifest.version)") } ?? "")+"\n"+L("Review Installation")
    case .open(let package): return "\(package.manifest.displayName) · \(package.manifest.version)   \(package.enabled ? L("Enabled") : L("Disabled"))\n\(controller.sourceTitle(for: package))"
    case .cancel: return L("取消")
    case .approve: return controller.review?.replacingVersion == nil ? L("同意以上能力并安装") : L("同意以上能力并更新")
    case .toggle(let package): return package.enabled ? L("停用这个插件") : L("启用这个插件")
    case .remove: return L("移除插件…")
    case .confirmRemove: return L("确认移除插件及其 MacTV 登录状态")
    case .info(let value): return value
    case .reload: return L("重新读取安装清单")
    case .reviewRecovery: return L("审阅安装清单恢复…")
    case .confirmRecovery: return L("备份原件并重建安装登记")
    }
  }
}

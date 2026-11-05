import MTVCore
import SwiftUI

struct SMBPanel: View {
  @ObservedObject var controller: SMBController
  var body: some View {
    ZStack {
      TVPopupBackdrop()
      VStack(alignment: .leading, spacing: 20) {
        Text(LT(
          controller.phase == "profiles"
            ? "已保存的 NAS"
            : (controller.phase == "confirmDelete"
              ? "删除已保存连接？" : (controller.phase == "browseError" ? "目录读取失败" : (controller.phase == "browse" ? "选择影片目录" : "连接 NAS")))
        ))
        .font(.system(size: 32, weight: .bold))
        if !controller.directoryLabel.isEmpty {
          Text(controller.directoryLabel).font(.system(size: 18)).foregroundStyle(.secondary)
            .lineLimit(2)
        }
        if controller.phase == "connecting" || controller.phase == "loading"
          || controller.phase == "saving"
        {
          HStack(spacing: 14) {
            ProgressView()
            Text(LT(
              controller.phase == "saving"
                ? "正在保存…" : (controller.phase == "loading" ? "正在读取目录…" : "正在连接…")))
          }
        }
        if !controller.message.isEmpty {
          Text(LT(controller.message)).foregroundStyle(.orange).lineLimit(3)
        }
        if controller.phase == "browseError", controller.directoryReadPending {
          ProgressView(L("前次目录读取仍在等待系统返回…")).controlSize(.small)
        }
        ScrollViewReader { scroll in
          ScrollView {
            VStack(spacing: 10) {
              ForEach(Array(controller.controls.enumerated()), id: \.offset) { index, control in
                TVButton(
                  selected: controller.selection == index,
                  action: {
                    controller.selection = index
                    controller.activate()
                  },
                  hover: { controller.selection = index }
                ) {
                  HStack(spacing: 18) {
                    if case .folder = control { Image(systemName: "folder") }
                    Text(label(control)).font(.system(size: 20, weight: .medium))
                      .lineLimit(2).truncationMode(.middle)
                    Spacer()
                    Text(value(control)).font(.system(size: 18)).foregroundStyle(.secondary)
                      .lineLimit(1)
                  }.padding(20).frame(maxWidth: .infinity)
                }.id(index)
              }
            }.padding(.horizontal, 18).padding(.vertical, 10)
          }.scrollIndicators(.hidden)
            .onAppear { scroll.scrollTo(controller.selection, anchor: .center) }
            .onChange(of: controller.selection) { _, index in
              withAnimation(.easeInOut(duration: 0.2)) { scroll.scrollTo(index, anchor: .center) }
            }
        }.id(controller.phase)
      }.padding(36).frame(width: 900, height: 620)
        .tvPopupSurface(radius: 28)
    }
  }
  private func label(_ control: SMBControl) -> String {
    switch control {
    case .address: return L("服务器与共享")
    case .mode: return L("登录方式")
    case .username: return L("账号")
    case .password: return L("密码")
    case .connect: return L("连接")
    case .connectRoot: return L("连接共享根目录")
    case .useDirectory: return L("使用这个目录")
    case .parent: return L("返回上层")
    case .close: return L("返回")
    case .rememberPassword: return L("记住密码")
    case .networkRecovery: return L("网络恢复后重连")
    case .saveProfile: return L("保存连接")
    case .savedConnections: return L("查看已保存连接")
    case .newConnection: return L("添加新连接")
    case .deleteProfile: return L("删除已保存连接")
    case .confirmDelete: return L("删除连接和已存密码")
    case .cancelDelete: return L("取消")
    case .profile(let id):
      guard let address = controller.profiles.first(where: { $0.id == id })?.address else {
        return L("连接不可用")
      }
      return address.removingPercentEncoding ?? address
    case .folder(let url): return url.lastPathComponent
    case .retryDirectory: return L("重试刚才的目录")
    case .browseRoot: return L("读取共享根目录")
    case .failureDetails: return L("查看错误与访问说明")
    case .reconnect: return L("返回连接设置")
    }
  }
  private func value(_ control: SMBControl) -> String {
    switch control {
    case .address: return controller.address.isEmpty ? "smb://nas/Movies" : controller.address
    case .mode: return controller.guest ? L("访客访问") : L("账号登录")
    case .username: return controller.username.isEmpty ? L("填写账号") : controller.username
    case .password:
      return controller.password.isEmpty
        ? (controller.storedPasswordAvailable ? L("已保存，连接时使用") : L("填写密码"))
        : String(repeating: "•", count: controller.password.count)
    case .rememberPassword: return controller.rememberPassword ? L("记住密码") : L("不保存")
    case .networkRecovery: return controller.reconnectOnNetworkReturn ? L("尝试一次，失败后手动处理") : L("关闭")
    case .profile(let id):
      guard let profile = controller.profiles.first(where: { $0.id == id }) else { return "" }
      return profile.guest ? L("访客") : profile.username
    default: return ""
    }
  }
}

import AppKit
import SwiftUI
import MTVCore

extension AppModel {
  var guideTitle: String { LT(["把影片带到大屏", "允许访问你的内容", "连接喜欢的应用", "准备好遥控和声音"][setupGuideStep]) }
  var guideDescription: String { LT([
    "选择影片所在的文件夹或 NAS。也可以先使用在线应用，稍后再添加影片。",
    "在“系统设置 → 隐私与安全性 → 完全磁盘访问权限”中，添加“应用程序”里的 MacTV 并开启开关，然后退出并重新打开 MacTV。此权限用于从 Chrome 导入登录，会扩大可读取的范围；普通影片播放和扫码登录不需要开启。",
    "选择哔哩哔哩或夸克网盘，扫码或从这台 Mac 的 Chrome 导入登录。首次导入时，请按系统提示输入“登录”钥匙串密码；信任 MacTV 时可选择“始终允许”。",
    "推荐使用遥控器或触控板。用方向键选择、确定键播放，Esc 或 Backspace 返回上一级。声音默认跟随系统，也可单独选择电视与扬声器。"
  ][setupGuideStep]) }
  var guideActions: [(String,String,String)] {
    switch setupGuideStep {
    case 0: return [("添加影片文件夹","这台 Mac 或外置硬盘中的影片","folder.badge.plus"),
      ("连接 NAS","家庭网络里的共享文件夹","externaldrive.connected.to.line.below"),
      ("管理影片来源","查看、切换或移除已添加的目录","rectangle.stack")]
    case 1: return [("打开完全磁盘访问权限","添加 MacTV 并开启开关，随后退出并重新打开 MacTV","externaldrive.badge.checkmark"),
      ("查看文件与文件夹权限","外置硬盘、网络宗卷等访问开关","folder.badge.gearshape")]
    case 2: return [("登录哔哩哔哩","扫码或在登录页选择从 Chrome 导入","play.tv"),
      ("登录夸克网盘","扫码或在登录页选择从 Chrome 导入","qrcode")]
    default: return [("选择声音输出","跟随系统，或单独选择电视与扬声器","speaker.wave.2")]
    }
  }
  func presentSetupGuide() {
    setupGuideStep = 0; setupGuideSelection = 0; setupGuideVisible = true
    if !CommandLine.arguments.contains("--ui-smoke") { UserDefaults.standard.set(true,forKey:"mtv.setup.seen") }
  }
  func finishSetupGuide(completed: Bool) {
    setupGuideVisible = false
    if !CommandLine.arguments.contains("--ui-smoke") {
      UserDefaults.standard.set(true,forKey:"mtv.setup.seen")
      if completed { UserDefaults.standard.set(true,forKey:"mtv.setup.completed") }
    }
  }
  func activateSetupGuide() {
    let count = guideActions.count, selected = setupGuideSelection
    if selected == count {
      if setupGuideStep > 0 { setupGuideStep -= 1; setupGuideSelection = 0 }
      return
    }
    if selected == count + 1 {
      if setupGuideStep == 3 { finishSetupGuide(completed:true) }
      else { setupGuideStep += 1; setupGuideSelection = 0 }
      return
    }
    if selected == count + 2 { finishSetupGuide(completed:false); return }
    guard guideActions.indices.contains(selected) else { return }
    switch (setupGuideStep,selected) {
    case (0,0): chooseRoot()
    case (0,1): smb.present()
    case (0,2): presentSavedSources()
    case (1,0): openSetupPrivacy("Privacy_AllFiles")
    case (1,1): openSetupPrivacy("Privacy_FilesAndFolders")
    case (2,0): if let plugin = plugins.first(where:{$0.id == "mtv.bilibili"}) { showLogin(plugin) }
    case (2,1): if let plugin = plugins.first(where:{$0.id == "mtv.quark"}) { showLogin(plugin) }
    case (3,0): presentAudioOutputs()
    default: break
    }
  }
  private func openSetupPrivacy(_ pane: String) {
    guard ["Privacy_AllFiles","Privacy_FilesAndFolders"].contains(pane),
      let url = URL(string:"x-apple.systempreferences:com.apple.preference.security?" + pane) else { return }
    NSWorkspace.shared.open(url)
  }
}

struct SetupGuide: View {
  @ObservedObject var model: AppModel
  var body: some View {
    ZStack {
      Color(white:0.025).ignoresSafeArea()
      VStack(alignment:.leading,spacing:22) {
        HStack(spacing:12) {
          ForEach(0..<4) { index in
            Capsule().fill(index <= model.setupGuideStep ? .white:.white.opacity(0.12)).frame(width:64,height:5)
          }
          Spacer()
          Text(LT("MacTV · 开始使用")).font(.system(size:16,weight:.medium)).foregroundStyle(.secondary)
        }
        Text(model.guideTitle).font(.system(size:44,weight:.bold)).tracking(-1)
        if model.setupGuideStep == 1 {
          Text(L("从 Chrome 导入登录时，开启完全磁盘访问后重新打开 MacTV。"))
            .font(.system(size: 16)).foregroundStyle(.secondary)
        }
        if model.setupGuideStep == 3 {
          VStack(alignment: .leading, spacing: 12) {
            Label(model.guideInputDevices?.summary ?? LT("正在检查已连接的遥控器与触控板…"), systemImage: "dpad")
              .font(.system(size: 16, weight: .medium)).lineLimit(2)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
              ForEach(TVKeyBindings.guide, id: \.action) { binding in
                HStack {
                  Text(LT(binding.action)).foregroundStyle(.secondary)
                  Spacer()
                  Text(LT(binding.keys)).fontWeight(.medium)
                }.font(.system(size: 16)).padding(14)
                  .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
              }
            }
          }.task {
            while !Task.isCancelled {
              model.guideInputDevices = await Task.detached(priority: .utility) { InputDeviceInventory.scan() }.value
              do { try await Task.sleep(for: .seconds(5)) } catch { return }
            }
          }
        }
        VStack(spacing:12) {
          ForEach(model.guideActions.indices,id:\.self) { index in
            let action = model.guideActions[index]
            TVButton(selected:model.setupGuideSelection == index,
              action:{ model.setupGuideSelection = index; model.activateSetupGuide() },hover:{ model.setupGuideSelection = index }) {
              HStack(spacing:22) {
                Image(systemName:action.2).font(.system(size:27)).frame(width:40)
                VStack(alignment:.leading,spacing:7) {
                  Text(LT(action.0)).font(.system(size:23,weight:.semibold))
                }
                Spacer(); Image(systemName:"chevron.right").foregroundStyle(.secondary)
              }.padding(22).frame(maxWidth:.infinity,alignment:.leading)
            }
          }
        }
        HStack(spacing:18) {
          footer(model.guideActions.count,"上一步").disabled(model.setupGuideStep == 0)
          Spacer()
          footer(model.guideActions.count + 2,"稍后设置")
          footer(model.guideActions.count + 1,model.setupGuideStep == 3 ? "开始使用":"下一步")
        }
      }.padding(40).frame(width:1060)
    }
  }
  private func footer(_ index: Int,_ title: String) -> some View {
    TVButton(selected:model.setupGuideSelection == index,
      action:{ model.setupGuideSelection = index; model.activateSetupGuide() },hover:{ model.setupGuideSelection = index }) {
      Text(LT(title)).font(.system(size:20,weight:.semibold)).padding(.horizontal,26).padding(.vertical,18)
    }
  }
}

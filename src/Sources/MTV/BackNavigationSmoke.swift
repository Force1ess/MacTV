import AppKit

extension UISmoke {
  /// Exercise the same key mapping and return stack as the native event monitor.
  /// These checks do not claim a physical remote event or foreground delivery.
  static func backNavigationSmoke(model: AppModel) -> [String: Bool] {
    var checks: [String: Bool] = [:]
    let oldAddress = model.smb.address
    defer {
      model.notice = nil
      if model.keyboardVisible { model.finishTextEntry(commit: false) }
      model.smb.address = oldAddress
      model.navigate(.home)
    }
    for (name, key) in [("backspace", UInt16(51)), ("escape", UInt16(53))] {
      func back() {
        if let action = TVKeyBindings.navigationAction(keyCode: key, keyboardVisible: model.keyboardVisible) { model.handle(action) }
      }
      model.navigate(.settings)
      model.performSetting(.information)
      model.notice = "Owned About notice"; back()
      checks[name + "AboutBackDismissesTopNoticeBeforeCredits"] = model.notice == nil && model.information.isPresented
      checks[name + "AboutShowsAttributionAndBundledNotices"] = model.information.isPresented
        && model.information.logo != nil && model.information.notices.contains { $0.id == "MacTV-LICENSE.txt" }
      model.information.selection = 2; model.handle(.select)
      checks[name + "AboutOpensLicenseList"] = model.information.page == .licenses
      if let ownLicense = model.information.notices.firstIndex(where: { $0.id == "MacTV-LICENSE.txt" }) {
        model.information.selection = ownLicense; model.handle(.select)
        checks[name + "AboutReadsActualBundledLicense"] = model.information.page == .document
          && model.information.document.contains("GNU GENERAL PUBLIC LICENSE")
      } else { checks[name + "AboutReadsActualBundledLicense"] = false }
      back()
      checks[name + "AboutDocumentBackKeepsLicenseList"] = model.information.isPresented && model.information.page == .licenses
      back()
      checks[name + "AboutLicenseListBackKeepsCredits"] = model.information.isPresented && model.information.page == .credits
      back()
      checks[name + "AboutBackReturnsToSettings"] = !model.information.isPresented && model.section == .settings
      model.appearanceVisible = true
      model.notice = "Notice fixture"
      back()
      checks[name + "DismissesOnlyTopNotice"] = model.notice == nil && model.appearanceVisible
      back()
      checks[name + "DismissesAppearanceToSettings"] = !model.appearanceVisible && model.section == .settings
      model.navigationCustomizationVisible = true
      back()
      checks[name + "DismissesNavigationSettings"] = !model.navigationCustomizationVisible && model.section == .settings
      model.smb.address = "original.invalid/Movies"
      model.showSMBTextEntry(.address)
      model.inputText = "draft.invalid/Films"
      back()
      checks[name + "CancelsTextEntryInsteadOfDeleting"] = !model.keyboardVisible && model.smb.address == "original.invalid/Movies"
      model.playbackSpeedVisible = true
      back()
      checks[name + "DismissesPlaybackSpeed"] = !model.playbackSpeedVisible
      model.navigate(.home)
      back()
      checks[name + "AtHomeKeepsApplicationOpen"] = model.section == .home
    }
    return checks
  }
}

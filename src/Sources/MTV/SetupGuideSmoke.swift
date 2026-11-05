import AppKit
import Foundation

extension UISmoke {
  static func setupGuideSmoke(model: AppModel,output: URL,window: NSWindow) async -> [String:Bool] {
    let seen = UserDefaults.standard.object(forKey:"mtv.setup.seen") as? Bool
    let completed = UserDefaults.standard.object(forKey:"mtv.setup.completed") as? Bool
    defer { model.finishSetupGuide(completed:false); model.audioOutputVisible = false; model.notice = nil; model.navigate(.home) }
    var checks: [String:Bool] = [:]
    model.navigate(.settings); model.performSetting(.about)
    checks["guideCanBeReopenedFromSettings"] = model.setupGuideVisible && model.setupGuideStep == 0
    for step in 0..<4 {
      checks["guideShowsStep-\(step)"] = model.setupGuideVisible && model.setupGuideStep == step && !model.guideActions.isEmpty
      await settle(); capture(window,to:output.appendingPathComponent("guide-\(step).png"))
      if step == 1 {
        checks["guideExplainsDiskSettingsWithoutInventingPermissionState"] = model.guideActions.count == 2
        model.handle(.back)
        checks["guideBackReturnsToPreviousStep"] = model.setupGuideStep == 0
        model.setupGuideSelection = model.guideActions.count + 1; model.handle(.select)
      }
      if step == 2 {
        checks["guideHasTwoPlatformEntriesWithoutDuplicateImport"] = model.guideActions.count == 2 && model.guideActions.allSatisfy { $0.1.contains("Chrome") }
      }
      if step == 3 {
        model.setupGuideSelection = 0; model.handle(.select)
        checks["guideAudioSetupUsesExistingDevicePicker"] = model.audioOutputVisible
        model.handle(.back)
        checks["guideModalBackReturnsToGuide"] = model.setupGuideVisible && !model.audioOutputVisible && model.setupGuideStep == 3
      }
      model.setupGuideSelection = model.guideActions.count + 1; model.handle(.select)
    }
    checks["guideFinishClosesWithoutChangingPermissionClaims"] = !model.setupGuideVisible
    model.presentSetupGuide(); model.setupGuideSelection = model.guideActions.count + 2; model.handle(.select)
    checks["guideCanBeSkipped"] = !model.setupGuideVisible
    checks["guideTestDoesNotWriteNormalSetupPreferences"] = (UserDefaults.standard.object(forKey:"mtv.setup.seen") as? Bool) == seen && (UserDefaults.standard.object(forKey:"mtv.setup.completed") as? Bool) == completed
    return checks
  }
}

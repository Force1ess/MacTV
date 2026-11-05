import AppKit

extension UISmoke {
  static func aboutMacTVSmoke(model: AppModel, output: URL) async -> [String: Bool] {
    let information = model.information, oldAppearance = model.appearance
    var checks: [String: Bool] = [:]
    defer { information.close(); model.appearance = oldAppearance }
    information.present(); await settle()
    if let window = NSApp.keyWindow { capture(window, to: output.appendingPathComponent("about-credits.png")) }
    checks["aboutLoadsApprovedAttributionArtwork"] = information.logo != nil
    checks["aboutCatalogIncludesNativeRuntimeNotices"] = information.notices.contains { $0.id.hasPrefix("MPVNativeEngine/licenses/mpv/") }
    information.selection = 2; model.handle(.select); await settle()
    checks["aboutIncludesFullFreeTypeLicense"] = information.notices.contains { $0.id.contains("freetype/") && $0.id.hasSuffix("FTL.TXT") }
    checks["aboutIncludesIJGLicenseReadme"] = information.notices.contains { $0.id.contains("jpeg-turbo/") && $0.id.hasSuffix("README.ijg") }
    checks["aboutIncludesFrozenRimeDependencyNotices"] = ["boost", "glog", "leveldb", "marisa-trie", "opencc", "yaml-cpp"].allSatisfy { component in
      information.notices.contains { $0.id.hasPrefix("RimeEngine/licenses/static-dependencies/\(component)/") }
    }
    if let rime = information.notices.firstIndex(where: { $0.id == "RimeEngine/licenses/static-dependencies/boost/LICENSE_1_0.txt" }) {
      information.selection = rime; model.handle(.select); await settle()
      checks["aboutRimeDependencyLicenseActuallyReadable"] = information.page == .document
        && information.document.contains("Boost Software License - Version 1.0")
        && (information.scrollView?.documentView as? NSTextView)?.string == information.document
      model.handle(.back); await settle()
    } else { checks["aboutRimeDependencyLicenseActuallyReadable"] = false }
    if let credits = information.notices.firstIndex(where: { $0.id == "Attribution/DEPENDENCY-NOTICES.txt" }) {
      information.selection = credits; model.handle(.select); await settle()
      checks["aboutDependencyAcknowledgementsAreActuallyReadable"] = information.page == .document
        && information.document.contains("This software is based in part on the work of the Independent JPEG Group.")
        && information.document.contains("MacTV uses the FreeType font engine")
      model.handle(.back); await settle()
    } else { checks["aboutDependencyAcknowledgementsAreActuallyReadable"] = false }
    guard let own = information.notices.firstIndex(where: { $0.id == "MacTV-LICENSE.txt" }) else {
      checks["aboutActualLicenseDocumentMounted"] = false; return checks
    }
    information.selection = own; model.handle(.select); await settle()
    guard let scroll = information.scrollView else { checks["aboutActualLicenseDocumentMounted"] = false; return checks }
    checks["aboutActualLicenseDocumentMounted"] = scroll.window != nil
      && (scroll.documentView as? NSTextView)?.string == information.document
    checks["aboutFullLicenseExceedsViewportWithoutTruncation"] = information.document.contains("END OF TERMS AND CONDITIONS")
      && (scroll.documentView?.bounds.height ?? 0) > scroll.contentView.bounds.height
    model.handle(.down); await settle()
    checks["aboutRemoteDownScrollsActualLicenseViewport"] = scroll.contentView.bounds.origin.y > 0
    let scrollPosition = scroll.contentView.bounds.origin.y
    model.appearance = .light; await settle()
    checks["aboutLicenseTextFollowsLightAppearanceWithoutLosingScroll"] =
      (scroll.documentView as? NSTextView)?.textColor == .black && scroll.contentView.bounds.origin.y == scrollPosition
    model.appearance = .dark; await settle()
    checks["aboutLicenseTextFollowsDarkAppearanceWithoutLosingScroll"] =
      (scroll.documentView as? NSTextView)?.textColor == .white && scroll.contentView.bounds.origin.y == scrollPosition
    model.handle(.up); await settle()
    checks["aboutRemoteUpReturnsLicenseViewportToStart"] = scroll.contentView.bounds.origin.y == 0
    if let window = NSApp.keyWindow { capture(window, to: output.appendingPathComponent("about-license.png")) }
    model.handle(.back); await settle()
    checks["aboutNativeDocumentUnmountsOnBack"] = information.page == .licenses && information.scrollView == nil
    return checks
  }
}

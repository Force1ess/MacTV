import Foundation
import Testing
@testable import MTVCore

struct PluginAppLaunchTests {
  @Test func namedWindowRulesAreDeclaredRatherThanHardcodedInTheHost() throws {
    let declaration: [String:Any] = ["bundleID":"com.example.games","url":"example://open/lounge","returnWhen":"matched-window-closes","windowTitles":["Example Lounge"],"preferredPresentation":"fullscreen"]
    let value=try JSONDecoder().decode(PluginAppLaunch.self,from:JSONSerialization.data(withJSONObject:declaration))
    try value.validate()
    #expect(value.windowTitles==["Example Lounge"])
    var missing=declaration; missing.removeValue(forKey:"windowTitles")
    #expect(throws: Error.self) { try JSONDecoder().decode(PluginAppLaunch.self,from:JSONSerialization.data(withJSONObject:missing)).validate() }
    var broad=declaration; broad["windowTitles"]=[String(repeating:"x",count:121)]
    #expect(throws: Error.self) { try JSONDecoder().decode(PluginAppLaunch.self,from:JSONSerialization.data(withJSONObject:broad)).validate() }
  }
  @Test func returningNeverStealsFocusFromAnUnrelatedApplication() {
    #expect(!LauncherReturnPolicy.shouldActivate(applicationRunning:true,selectedApplicationFront:false,hostFront:false,lastSelectedApplicationFront:true))
    #expect(!LauncherReturnPolicy.shouldActivate(applicationRunning:false,selectedApplicationFront:false,hostFront:false,lastSelectedApplicationFront:false))
    #expect(LauncherReturnPolicy.shouldActivate(applicationRunning:true,selectedApplicationFront:true,hostFront:false,lastSelectedApplicationFront:false))
    #expect(LauncherReturnPolicy.shouldActivate(applicationRunning:false,selectedApplicationFront:false,hostFront:false,lastSelectedApplicationFront:true))
  }
  @Test func processFamilyIncludesHelpersOutsideTheApplicationBundle() throws {
    let child = Process(); child.executableURL = URL(fileURLWithPath:"/bin/sleep"); child.arguments = ["5"]
    try child.run(); defer { if child.isRunning { child.terminate() }; child.waitUntilExit() }
    #expect(ApplicationProcessFamily.descendants(of:[getpid()]).contains(child.processIdentifier))
  }
  @Test func fullscreenHandoffToAnOwnedGameWindowDoesNotFinishSession() {
    var tracker = FullscreenSessionTracker(baseline:[])
    tracker.observe(fullscreenWindows:[2],applicationRunning:true)
    tracker.observe(fullscreenWindows:[3],applicationRunning:true)
    #expect(tracker.windowID == 3 && !tracker.finished)
  }
  private func declaration(_ url: String) throws -> PluginAppLaunch {
    try JSONDecoder().decode(PluginAppLaunch.self, from: JSONSerialization.data(withJSONObject:
      ["bundleID":"com.example.games", "url":url, "returnWhen":"fullscreen-window-closes"]))
  }
  @Test func onlyFixedApplicationIntentsAreAccepted() throws {
    try declaration("steam://open/bigpicture").validate()
    for url in ["file:///tmp/a", "https://example.com", "steam://open/bigpicture?command=quit", "steam://u:p@open/bigpicture", "steam://open/%20bad", "javascript:alert(1)"] {
      #expect(throws: Error.self) { try declaration(url).validate() }
    }
  }
  @Test func returnTracksWindowExitWhileApplicationKeepsRunning() {
    var tracker = FullscreenSessionTracker(baseline: [1])
    tracker.observe(fullscreenWindows: [1], applicationRunning: true)
    #expect(tracker.windowID == nil)
    tracker.observe(fullscreenWindows: [1, 2], applicationRunning: true)
    #expect(tracker.windowID == 2)
    tracker.observe(fullscreenWindows: [1], applicationRunning: true)
    #expect(!tracker.finished)
    tracker.observe(fullscreenWindows: [1, 2], applicationRunning: true)
    #expect(!tracker.finished)
    tracker.observe(fullscreenWindows: [1], applicationRunning: true)
    tracker.observe(fullscreenWindows: [1], applicationRunning: true)
    #expect(tracker.finished)
  }
}

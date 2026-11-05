import AppKit
import Darwin
import Foundation

enum RuntimeTestGuard {
  static var supervisor: pid_t? {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of:"--supervised-ui-test"), index+1 < args.count,
      let pid = Int32(args[index+1]), pid > 1 else { return nil }
    return pid
  }
  static var installed: Bool { Bundle.main.bundleURL.standardizedFileURL.path == "/Applications/MacTV.app" }
  static func idleSeconds() -> Double {
    let types: [CGEventType] = [.keyDown,.leftMouseDown,.rightMouseDown,.mouseMoved,.scrollWheel,.flagsChanged]
    return min(86_400,types.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:$0) }.min() ?? 0)
  }
  static func runGuardianIfRequested() {
    let args = CommandLine.arguments
    guard let index = args.firstIndex(of:"--test-runtime-guardian") else { return }
    guard index+1 < args.count, let supervisor = Int32(args[index+1]), supervisor > 1,
      let executable = Bundle.main.executableURL else { exit(64) }
    signal(SIGTERM,SIG_DFL)
    let parent = getppid()
    var path = [CChar](repeating:0,count:4096)
    let length = path.withUnsafeMutableBytes { proc_pidpath(parent,$0.baseAddress,UInt32($0.count)) }
    guard length > 0, String(cString:path) == executable.path else { exit(64) }
    let started = ProcessInfo.processInfo.systemUptime
    var requestedStop = false
    var backgroundRecovery = false
    while getppid() == parent {
      let elapsed = ProcessInfo.processInfo.systemUptime-started
      let supervisorGone = kill(supervisor,0) != 0 && errno == ESRCH
      let userReturned = elapsed > 1 && idleSeconds() < elapsed-0.2
      if !requestedStop && (supervisorGone || userReturned) {
        backgroundRecovery = NSWorkspace.shared.frontmostApplication?.bundleIdentifier != Bundle.main.bundleIdentifier
        kill(parent,SIGTERM); requestedStop = true
      }
      Thread.sleep(forTimeInterval:0.2)
    }
    let reopen = Process(); reopen.executableURL = URL(fileURLWithPath:"/usr/bin/open")
    reopen.arguments = ["-n",Bundle.main.bundleURL.path,"--args","--windowed","--enable-control"]
    if backgroundRecovery { reopen.arguments?.append("--background-recovery") }
    do { try reopen.run(); reopen.waitUntilExit(); exit(0) } catch { exit(70) }
  }
  static func startGuardian() throws {
    guard installed, CommandLine.arguments.contains("--ui-smoke"), let supervisor else { return }
    let process = Process(); process.executableURL = Bundle.main.executableURL
    process.arguments = ["--test-runtime-guardian",String(supervisor)]
    process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    try process.run()
  }
}

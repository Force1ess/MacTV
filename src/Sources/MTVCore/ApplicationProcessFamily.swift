import Darwin
import Foundation

/// Read only the selected application's process descendants. Steam stores its
/// web helper outside the installation bundle, so bundle paths alone miss it.
public enum ApplicationProcessFamily {
  public static func descendants(of roots: Set<pid_t>) -> Set<pid_t> {
    var result = roots, pending = Array(roots.prefix(64))
    while let parent = pending.popLast(), result.count < 256 {
      var children = [pid_t](repeating:0,count:256)
      let count = children.withUnsafeMutableBytes { proc_listchildpids(parent,$0.baseAddress,Int32($0.count)) }
      guard count > 0 else { continue }
      // proc_listchildpids returns a PID count, unlike proc_listpids' byte count.
      for pid in children.prefix(min(children.count,Int(count))) where pid > 0 {
        if result.insert(pid).inserted { pending.append(pid) }
        if result.count >= 256 { break }
      }
    }
    return result
  }
}

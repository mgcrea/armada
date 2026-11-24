import Darwin
import Foundation

/// What the kernel says about a process, through `kinfo_proc` as `ps` reads it: who its parents
/// are (the nesting rule), when it started (a holder record's guard against pid reuse) and what
/// it runs. Each answer is empty or nil where the kernel or a sandbox refuses, and the callers
/// carry on without it: nesting then falls back to its same-tree rule.
public enum ProcessTree {
  /// Every ancestor of `pid`, nearest first, stopping short of launchd. The visited set guards
  /// against a cycle that pid reuse between two reads of a changing table could produce.
  public static func ancestors(of pid: Int32, maxDepth: Int = 32) -> [Int32] {
    var chain: [Int32] = []
    var seen: Set<Int32> = [pid]
    var current = pid
    while chain.count < maxDepth, let next = info(of: current)?.kp_eproc.e_ppid, next > 1 {
      guard seen.insert(next).inserted else { break }
      chain.append(next)
      current = next
    }
    return chain
  }

  /// When the kernel says the process started. The field is `kp_proc.p_un.__p_starttime`:
  /// `sys/proc.h`'s `p_starttime` macro for it is invisible to Swift.
  public static func startTime(of pid: Int32) -> Date? {
    guard let time = info(of: pid)?.kp_proc.p_un.__p_starttime else { return nil }
    return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
  }

  /// The executable's file name: from its full path, which `proc_pidpath` may refuse, else the
  /// kernel's `p_comm`, cut at 16 characters.
  public static func executableName(of pid: Int32) -> String? {
    var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
    if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
      let path = String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
      return (path as NSString).lastPathComponent
    }
    guard var info = info(of: pid) else { return nil }
    let name = withUnsafeBytes(of: &info.kp_proc.p_comm) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    return name.isEmpty ? nil : name
  }

  /// One `kinfo_proc`, or nil when the pid is gone or the read is refused. For a pid that does
  /// not exist `sysctl` returns 0 and writes nothing, so the size and pid are checked too:
  /// a zeroed struct would read as a process whose parent is 0.
  private static func info(of pid: Int32) -> kinfo_proc? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0,
      info.kp_proc.p_pid == pid
    else { return nil }
    return info
  }
}

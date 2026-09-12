import Darwin
import Foundation

/// What the kernel will say about a pid.
///
/// A session registry file gives a pid and nothing else about where the session
/// lives — no tty, no window, no host application. The pid is the only handle, so
/// everything Armada knows about *where* a session is running is derived here, by
/// asking the kernel about the process and its ancestors.
///
/// **No permission of any kind is needed.** `KERN_PROC_PID` is readable for every
/// process regardless of owner — this is what `ps` does, and it has to work that way
/// here: `login` runs as uid 0 and sits in the middle of every Terminal session's
/// process chain.
///
/// One `sysctl` per hop, a few hundred bytes copied each time, about five hops. The
/// expensive part of finding a session's host is not in this file — see
/// `SessionHostLookup`.
nonisolated enum ProcessAncestry {
  /// One `kinfo_proc`, or nil if the pid is gone.
  ///
  /// **The `size` and pid checks are not defensive noise.** For a pid that does not
  /// exist, `sysctl` returns 0 and writes nothing, so the return code on its own
  /// would hand back a zeroed struct that reads as a real process with ppid 0.
  static func info(of pid: pid_t) -> kinfo_proc? {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0,
      size > 0,
      info.kp_proc.p_pid == pid
    else { return nil }
    return info
  }

  static func parent(of pid: pid_t) -> pid_t? {
    guard let ppid = info(of: pid)?.kp_eproc.e_ppid, ppid > 0 else { return nil }
    return ppid
  }

  /// Every ancestor, nearest first, stopping short of launchd.
  ///
  /// Bounded three ways — a depth cap, `pid > 1`, and a visited set — because the
  /// chain is assembled from separate reads of a table that is changing underneath
  /// them. The visited set is the one that looks redundant and is not: **pids wrap
  /// on this machine** (a pid of 344 whose parent was 98106 was observed on
  /// 2026-09-11), so a race between two reads can produce a cycle that the depth cap
  /// alone would happily walk sixteen times.
  static func ancestors(of pid: pid_t, maxDepth: Int = 16) -> [pid_t] {
    var chain: [pid_t] = []
    var seen: Set<pid_t> = [pid]
    var current = pid
    while chain.count < maxDepth, let next = parent(of: current), next > 1 {
      guard seen.insert(next).inserted else { break }
      chain.append(next)
      current = next
    }
    return chain
  }

  /// When the kernel says the process started.
  ///
  /// This is the guard against pid reuse. A crashed session leaves its
  /// `sessions/<pid>.json` behind and pids wrap, so a stale registry file can name a
  /// pid that now belongs to a stranger — and acting on that would raise somebody
  /// else's application. Comparing against the registry's own `startedAt` settles it.
  ///
  /// Measured 2026-09-11 against pid 90861: the registry said
  /// `"startedAt":1789160285921` and `ps -o lstart` said `Fri Sep 11 22:58:04 2026`.
  /// They agree to the second, so a tolerance of a few seconds is ample.
  ///
  /// The field is spelled `kp_proc.p_un.__p_starttime`. `sys/proc.h` defines a
  /// `p_starttime` macro for it that C sees and Swift does not.
  static func startTime(of pid: pid_t) -> Date? {
    guard let time = info(of: pid)?.kp_proc.p_un.__p_starttime else { return nil }
    return Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_usec) / 1_000_000)
  }

  /// The executable's full path, or nil.
  ///
  /// Needed because `kp_proc.p_comm` is useless for this: `MAXCOMLEN` is 16, which
  /// truncates `Code Helper (Plugin)` well past the point of recognition.
  ///
  /// This is allowed to fail where `sysctl` above does not, so the ancestry walk
  /// never depends on it — a nil here only means the bundle fallback in
  /// `SessionHostLookup` does not apply to that hop. Being owned by root is *not*
  /// on its own a reason it fails: checked 2026-09-11 against `login` (uid 0, pid
  /// 2115), which returned `/usr/bin/login` to an unprivileged caller.
  static func executablePath(of pid: pid_t) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(cString: buffer)
  }

  /// The controlling terminal as `/dev/ttys004`, or nil for a process that has none.
  ///
  /// **Nil for every VS Code-hosted session, which today is most of them.** Measured
  /// 2026-09-11: all twenty `claude` processes on this Mac show `??` under
  /// `ps -o tty`, because the extension speaks to the CLI over pipes and never
  /// allocates a pty. So this says nothing at all about the common case.
  ///
  /// It is here for the terminal case and for the deferred exact-tab work described
  /// in `docs/focusing-sessions.md`: Terminal.app and iTerm2 both expose a `tty`
  /// property on the scripting object that owns a pane, which makes a tty an *exact*
  /// key for a tab rather than a heuristic.
  ///
  /// `devname_r` rather than `devname`, because devname(3) says the latter "uses a
  /// static buffer, which will be overwritten on subsequent calls".
  static func controllingTTY(of pid: pid_t) -> String? {
    guard let device = info(of: pid)?.kp_eproc.e_tdev, device != -1 else { return nil }
    var buffer = [CChar](repeating: 0, count: 128)
    guard devname_r(device, mode_t(S_IFCHR), &buffer, Int32(buffer.count)) != nil else {
      return nil
    }
    let name = String(cString: buffer)
    // `devname_r` falls back to a `#C:major:minor` spelling when it cannot name the
    // device, which is not a path and not useful to anything downstream.
    guard !name.isEmpty, !name.hasPrefix("#") else { return nil }
    return "/dev/" + name
  }
}

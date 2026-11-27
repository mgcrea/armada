import Darwin
import Foundation

/// Which Antigravity conversations a running `agy` owns.
///
/// `presence/<id>.lock` stays on disk after its process exits, so its existence says nothing.
/// While a process owns the conversation it holds the file open (and a shared flock on it),
/// TUI and headless alike. Armada never takes the flock to ask, for `CodexLocks`' reason: the
/// lock keeps a second process off a conversation, and Armada holding it at the wrong moment
/// could stop a real session from opening. It lists the open files of the `agy` processes
/// instead, which also gives the pid. See docs/antigravity-sessions.md.
nonisolated enum AntigravityPresence {
  /// The process holding a conversation's lock, with its start time so a reused pid can be
  /// told apart later.
  struct Holder: Sendable, Hashable {
    let pid: Int32
    let startedAt: Date
    /// The process's working directory, which is the conversation's folder: `agy` has no
    /// `--cwd`. Nil when the kernel would not say.
    let cwd: String?

    init(pid: Int32, startedAt: Date, cwd: String? = nil) {
      self.pid = pid
      self.startedAt = startedAt
      self.cwd = cwd
    }
  }

  /// `SessionCloserBridge.startTolerance`'s value, repeated because this file is checked by
  /// `make unit` without the bridge: how far a scan's start time may sit from the kernel's.
  static let startTolerance: TimeInterval = 5

  /// The `agy` a close or focus is about to reach is the one a scan saw: its pid has not been
  /// handed to another process since. A pid the kernel no longer knows (`actual` nil) is not.
  static func startMatches(claimed: Date, actual: Date?) -> Bool {
    guard let actual else { return false }
    return abs(actual.timeIntervalSince(claimed)) < startTolerance
  }

  /// The conversation id, lowercased, when `lockPath` is `<presenceDir>/<uuid>.lock`.
  ///
  /// The kernel hands back resolved paths (`/private/tmp`, not `/tmp`), so the caller passes
  /// `presenceDir` through `realpath` once; the comparison here is plain text.
  static func conversationId(lockPath: String, presenceDir: String) -> String? {
    let directory = presenceDir.hasSuffix("/") ? String(presenceDir.dropLast()) : presenceDir
    let prefix = directory + "/"
    guard lockPath.hasPrefix(prefix) else { return nil }
    let name = lockPath.dropFirst(prefix.count)
    guard !name.contains("/"), name.hasSuffix(".lock") else { return nil }
    let id = String(name.dropLast(".lock".count))
    return UUID(uuidString: id) != nil ? id.lowercased() : nil
  }

  /// Every conversation an `agy` process holds open, by id. The language server each `agy`
  /// runs is a child under another name and is not asked. When two processes hold one lock,
  /// the one started first wins, so a scan's answer does not depend on pid order.
  static func holders(presenceDir: URL) -> [String: Holder] {
    guard let resolved = realPath(presenceDir.path(percentEncoded: false)) else { return [:] }
    var found: [String: Holder] = [:]
    for pid in ProcessAncestry.allPIDs() where isAgy(pid) {
      guard let startedAt = ProcessAncestry.startTime(of: pid) else { continue }
      for path in openVnodePaths(of: pid) {
        guard let id = conversationId(lockPath: path, presenceDir: resolved) else { continue }
        if let current = found[id], current.startedAt <= startedAt { continue }
        found[id] = Holder(pid: pid, startedAt: startedAt, cwd: workingDirectory(of: pid))
      }
    }
    return found
  }

  /// A process's current directory, as the kernel resolves it (`/private/tmp`, not `/tmp`), or
  /// nil for another user's process or one that just exited.
  static func workingDirectory(of pid: pid_t) -> String? {
    var info = proc_vnodepathinfo()
    let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
    guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
    let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { bytes in
      String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
    }
    return path.isEmpty ? nil : path
  }

  /// `agy` by its executable's name. `proc_pidpath` already gives the resolved path, so a
  /// symlink named `agy` to a binary under another name would not be recognised.
  private static func isAgy(_ pid: pid_t) -> Bool {
    guard let path = ProcessAncestry.executablePath(of: pid) else { return false }
    return URL(filePath: path).lastPathComponent == "agy"
  }

  /// The paths of a process's open files, or none when the kernel will not say (another
  /// user's process, or one that just exited).
  private static func openVnodePaths(of pid: pid_t) -> [String] {
    let fdStride = MemoryLayout<proc_fdinfo>.stride
    let needed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard needed > 0 else { return [] }
    // A margin for files opened between the two calls.
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(needed) / fdStride + 16)
    let filled = fds.withUnsafeMutableBytes {
      proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
    }
    guard filled > 0 else { return [] }
    var paths: [String] = []
    for fd in fds.prefix(Int(filled) / fdStride)
    where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
      var info = vnode_fdinfowithpath()
      let size = Int32(MemoryLayout<vnode_fdinfowithpath>.stride)
      guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else {
        continue
      }
      let path = withUnsafeBytes(of: info.pvip.vip_path) { bytes in
        String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
      }
      if !path.isEmpty { paths.append(path) }
    }
    return paths
  }

  private static func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
  }
}

import Darwin
import Foundation

/// One run of a shell, for what a person's login profile sets up.
///
/// **Bounded however the profile behaves**, which a pipe and `terminate()` were not
/// (measured 2026-10-12): an interactive zsh or bash ignores SIGTERM, so a profile that
/// hangs ran on past the deadline; and a job the profile starts in the background, an
/// agent or a `(sleep &)`, inherits the pipe and holds it open after the shell has exited
/// cleanly, so reading to its end waited on the job. So the script writes to a file, the
/// shell gets nothing to inherit, and at the deadline its whole process group is killed.
nonisolated enum LoginShell {
  /// What `script` prints when `shell` runs it with `flags`, or nil if it cannot be run or
  /// `timeout` passes first. `flags` end with the one that takes a command, `-c`.
  static func run(shell: String, flags: [String], script: String, timeout: TimeInterval) async
    -> Data?
  {
    let fileManager = FileManager.default
    let file = fileManager.temporaryDirectory.appending(
      path: "armada-shell-\(UUID().uuidString)", directoryHint: .notDirectory)
    guard
      fileManager.createFile(
        atPath: file.path(percentEncoded: false), contents: nil,
        attributes: [.posixPermissions: 0o600])
    else { return nil }
    defer { try? fileManager.removeItem(at: file) }

    let process = Process()
    process.executableURL = URL(filePath: shell)
    // The file reaches the script as `$1`, never spliced into its text.
    process.arguments =
      flags + ["{ \(script); } > \"$1\"", "armada", file.path(percentEncoded: false)]
    process.currentDirectoryURL = fileManager.homeDirectoryForCurrentUser
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    let finished = await withCheckedContinuation {
      (continuation: CheckedContinuation<Bool, Never>) in
      let once = Once(continuation)
      process.terminationHandler = { _ in once.resume(true) }
      do { try process.run() } catch {
        once.resume(false)
        return
      }
      DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
        guard once.resume(false) else { return }
        // A `Process` child leads its own process group, so this reaches whatever the
        // shell started in the foreground too. SIGKILL, because SIGTERM is ignored.
        let pid = process.processIdentifier
        guard pid > 1 else { return }
        // The group only when the shell leads it and it is not this process's own: a
        // negative pid that named Armada's group would take Armada down with it.
        if getpgid(pid) == pid, pid != getpgrp() { kill(-pid, SIGKILL) }
        kill(pid, SIGKILL)
      }
    }
    guard finished else { return nil }
    return try? Data(contentsOf: file)
  }

  /// A continuation resumed by whichever of the exit and the deadline comes first.
  private final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }

    /// Whether this call was the one that resumed it.
    @discardableResult
    func resume(_ finished: Bool) -> Bool {
      let waiting = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
        defer { continuation = nil }
        return continuation
      }
      waiting?.resume(returning: finished)
      return waiting != nil
    }
  }
}

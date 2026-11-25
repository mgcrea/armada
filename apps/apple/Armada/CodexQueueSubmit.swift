import ArmadaProcess
import Foundation

/// Running `codex queue`. See `CodexQueue` for what Codex does with the message.
nonisolated extension CodexQueue {
  /// Long enough for a cold `codex` start; the CLI itself returns in a fraction of a second.
  static let timeout: Duration = .seconds(15)

  /// `submit` with each copy in turn while the copy is too old, so an old `codex` early on the
  /// search path does not hide a newer one in ChatGPT or VS Code.
  static func submit(thread: String, text: String, home: String, executables: [URL]) async
    -> Submission
  {
    for executable in executables {
      let submission = await submit(thread: thread, text: text, home: home, executable: executable)
      if submission != .tooOld { return submission }
    }
    return executables.isEmpty ? .failed("Armada cannot find codex on this Mac.") : .tooOld
  }

  /// Runs `codex queue` against `home`, for at most `timeout`: then `SIGTERM` to its process
  /// group, so anything it started that holds the pipes goes too, and `SIGKILL` after a grace.
  static func submit(thread: String, text: String, home: String, executable: URL) async
    -> Submission
  {
    var environment = ProcessInfo.processInfo.environment
    environment["CODEX_HOME"] = home
    guard
      let finished = await ChildProcess.collect(
        executable,
        // `--message=` rather than `--message` and a separate argument: a text that starts with
        // a dash would otherwise be read as a flag.
        arguments: ["queue", "--thread", thread, "--message=\(text)"],
        environment: environment, timeout: timeout)
    else { return .failed("Armada could not run codex, or it did not finish in time.") }

    if let item = queuedItem(in: String(decoding: finished.standardOutput, as: UTF8.self)) {
      return .queued(item: item)
    }
    let message = String(decoding: finished.standardError, as: UTF8.self)
    return isTooOld(stderr: message) ? .tooOld : .failed(failure(stderr: message))
  }
}

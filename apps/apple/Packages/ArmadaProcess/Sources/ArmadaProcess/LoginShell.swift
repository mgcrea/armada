import Foundation
import Subprocess

/// One run of a shell, for what a person's login profile sets up.
///
/// **Bounded however the profile behaves**, which a pipe and `terminate()` were not (measured
/// 2026-10-12): an interactive zsh or bash ignores SIGTERM, so a profile that hangs ran on past
/// the deadline; and a job the profile starts in the background, an agent or a `(sleep &)`,
/// inherits stdout. So the shell is stopped with SIGKILL to its process group at the deadline, and
/// the script writes to a file: a job holding a pipe would hold the read open (`ChildProcess`
/// would read past that now) and, once Armada stopped reading, be sent `SIGPIPE` by its next write
/// to stdout. A file it can write to for as long as it likes.
public enum LoginShell {
  /// What `script` prints when `shell` runs it with `flags`, or nil if it cannot be run or
  /// `timeout` passes first. `flags` end with the one that takes a command, `-c`.
  @concurrent
  public static func run(shell: String, flags: [String], script: String, timeout: TimeInterval)
    async -> Data?
  {
    guard !Task.isCancelled else { return nil }
    let fileManager = FileManager.default
    let file = fileManager.temporaryDirectory.appending(
      path: "armada-shell-\(UUID().uuidString)", directoryHint: .notDirectory)
    guard
      fileManager.createFile(
        atPath: file.path(percentEncoded: false), contents: nil,
        attributes: [.posixPermissions: 0o600])
    else { return nil }
    defer { try? fileManager.removeItem(at: file) }

    let configuration = ChildProcess.configuration(
      URL(filePath: shell),
      // The file reaches the script as `$1`, never spliced into its text.
      arguments: flags + ["{ \(script); } > \"$1\"", "armada", file.path(percentEncoded: false)],
      environment: nil, directory: fileManager.homeDirectoryForCurrentUser, stop: .kill)
    let exited = await ChildProcess.bounded(.seconds(timeout)) {
      try await Subprocess.run(configuration, input: .none, output: .discarded, error: .discarded)
        .terminationStatus
    }
    guard exited != nil else { return nil }
    return try? Data(contentsOf: file)
  }
}

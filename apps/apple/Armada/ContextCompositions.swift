import Foundation

/// One account's probed compositions, keyed by project directory.
///
/// **Cached for the life of the process, and deliberately not invalidated on a
/// timer.** What it holds changes only when the config behind it does — a `CLAUDE.md`
/// edit, a skill added, an MCP server wired — and each answer costs a `claude`
/// process and about a second. Re-probing on the account's 30-second config poll
/// would spend a process per project per half-minute to re-learn a number that had
/// not moved. The panel shows when each was measured instead, which is the same
/// answer `StalenessBadge` gives for the usage cache: say how old it is rather than
/// pretend it is live.
///
/// Keyed by cwd rather than by session: two sessions in one project load the same
/// prefix, and the probe cannot tell them apart anyway.
@Observable
final class ContextCompositions {
  private let folder: ClaudeConfigFolder
  private var byDirectory: [String: ContextComposition] = [:]
  /// Directories with a probe in flight, so a selection bouncing between two rows
  /// does not start the same process twice.
  private var inFlight: Set<String> = []
  /// Directories whose probe came back empty. Held so a project that cannot be
  /// probed — no binary, a timeout — is not retried on every selection change.
  private var failed: Set<String> = []

  init(folder: ClaudeConfigFolder) {
    self.folder = folder
  }

  func composition(for cwd: String) -> ContextComposition? { byDirectory[cwd] }

  /// Probe this directory unless it is already known, already running, or already
  /// known to fail.
  func probe(cwd: String) async {
    guard byDirectory[cwd] == nil, !inFlight.contains(cwd), !failed.contains(cwd) else { return }
    // Not a directory any more — a project deleted while Armada watched it. The
    // subprocess would fail on `currentDirectoryURL` anyway; this is the cheap check.
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return }

    inFlight.insert(cwd)
    defer { inFlight.remove(cwd) }

    let folder = self.folder
    let url = URL(filePath: cwd, directoryHint: .isDirectory)
    let probed = await Task.detached(priority: .utility) {
      ContextProbe.run(folder: folder, cwd: url)
    }.value

    if let probed {
      byDirectory[cwd] = probed
    } else {
      failed.insert(cwd)
    }
  }
}

import AppKit
import Foundation

/// Start a new agent session, in a project, on a chosen account.
///
/// **This is the one thing in Armada that launches an agent**, and it is a narrow
/// one: it opens a terminal window sitting in a folder with `claude` or `codex`
/// running in it, exactly as the person would have done from a shell. Armada does not
/// own the process, does not hold its pipes and does not talk to it — the session
/// comes back through `SessionWatcher` / `CodexWatcher` like any other, within a poll.
/// `docs/design.md`'s "v1 watches; it doesn't launch agents" said the app observes
/// sessions started elsewhere; this makes Armada one of the elsewheres, and stops
/// there. Nothing here prompts, resumes or reads a transcript.
///
/// **Everything the session needs goes in the script, because nothing else survives
/// the trip.** The new window's environment comes from the terminal, not from Armada
/// (see `TerminalApp`), and the user's own `.zshrc` runs before the script does. So
/// the script is written to state the account outright rather than to inherit it, and
/// the `unset` below is not defensive tidying: a shell profile that exports
/// `CLAUDE_CONFIG_DIR` for a second account would otherwise silently start every
/// "Default" session on that other account.
nonisolated enum NewSession {
  /// Which agent, on which account. The config folder and the home are the account —
  /// see `Account` and `CodexAccount`, both of which are organised around exactly that.
  enum Agent: Hashable, Sendable {
    case claude(ClaudeConfigFolder)
    case codex(CodexHome)

    /// What the button says, and what an error message calls the missing binary.
    var commandName: String {
      switch self {
      case .claude: "claude"
      case .codex: "codex"
      }
    }

    var vendorName: String {
      switch self {
      case .claude: "Claude Code"
      case .codex: "Codex"
      }
    }
  }

  /// Open a terminal window running `agent` in `project`.
  ///
  /// Returns nil on success, or a sentence to put in front of the person. Every
  /// failure here is worth saying out loud, which is the opposite of the rule the
  /// probes follow: a probe that fails quietly costs a stale figure, and a launch that
  /// fails quietly is a button that does nothing.
  ///
  /// The LaunchServices half is asynchronous, so a failure from it arrives after this
  /// has returned and is reported through `completion` instead. Success reports
  /// nothing: the window is the feedback.
  @MainActor
  static func start(
    _ agent: Agent, in project: URL, terminal: TerminalApp,
    completion: @escaping @MainActor (String) -> Void = { _ in }
  ) -> String? {
    let fileManager = FileManager.default
    let path = project.standardizedFileURL.path(percentEncoded: false)

    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue
    else {
      return "\((path as NSString).abbreviatingWithTildeInPath) is not there any more."
    }

    guard let binary = executable(for: agent) else {
      return
        "Armada could not find the \(agent.commandName) command. It looks on your PATH and in the places \(agent.vendorName) installs itself; if yours lives somewhere else, start the session from your terminal as usual."
    }

    guard let application = terminal.applicationURL ?? TerminalApp.fallback.applicationURL else {
      return "Armada could not find \(terminal.name). Choose another terminal in Settings."
    }

    let script: URL
    do {
      script = try write(script: body(agent: agent, project: project, binary: binary), for: project)
    } catch {
      return "Armada could not write the startup script: \(error.localizedDescription)"
    }

    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = true
    NSWorkspace.shared.open([script], withApplicationAt: application, configuration: configuration)
    { _, error in
      guard let error else { return }
      Task { @MainActor in
        completion("\(terminal.name) could not start the session: \(error.localizedDescription)")
      }
    }
    return nil
  }

  private static func executable(for agent: Agent) -> URL? {
    switch agent {
    case .claude: ClaudeControl.executable()
    case .codex: CodexCLI.executable()
    }
  }

  /// The script itself.
  ///
  /// `zsh` by shebang rather than the user's login shell, so the syntax below is
  /// decided here rather than by whatever `$SHELL` happens to be — this runs on
  /// machines whose default shell is bash, and a script that is a syntax error in one
  /// of them is a window that flashes open and closes.
  ///
  /// **It waits on a failure and only on a failure.** Terminal closes a window whose
  /// shell exited cleanly, which is right for a session somebody finished, and wrong
  /// for a `claude` that died on its first line — that is the case where the whole
  /// feature reads as "the button does nothing", and the two lines below are what turn
  /// it into a message.
  private static func body(agent: Agent, project: URL, binary: URL) -> String {
    let path = project.standardizedFileURL.path(percentEncoded: false)
    var lines = [
      "#!/bin/zsh",
      "# Written by Armada to start a \(agent.vendorName) session. Safe to delete.",
      "cd \(quoted(path)) || exit 1",
    ]
    lines += accountLines(for: agent)
    lines += [
      quoted(binary.path(percentEncoded: false)),
      "status=$?",
      // `read -r` with no variable is zsh reading into REPLY, which is all this needs:
      // the keystroke is the point, not what was typed.
      "if [[ $status -ne 0 ]]; then",
      "  echo \"\"",
      "  echo \"\(agent.commandName) exited with status $status.\"",
      "  echo -n \"Press return to close this window… \"",
      "  read -r",
      "fi",
    ]
    return lines.joined(separator: "\n") + "\n"
  }

  /// The two lines that decide which account the session belongs to.
  ///
  /// **`unset` for the default Claude folder, and it is load-bearing.** Exporting
  /// `CLAUDE_CONFIG_DIR=~/.claude` is not a no-op — the default folder keeps its
  /// account file *beside* it rather than inside, so the variable sends Claude Code
  /// looking for `~/.claude/.claude.json`, which does not exist, and the session comes
  /// up as if signed out. Same asymmetry `ClaudeConfigFolder.usageJSON` exists to
  /// record and `ClaudeControl.environment(for:)` already handles for the probes.
  ///
  /// Codex has no such asymmetry — everything lives inside the home, default or not —
  /// so `CODEX_HOME` is always exported, which also overrides anything a shell profile
  /// set.
  ///
  /// **`path`, not `base.path`, and this line shipped wrong.** A trailing slash makes
  /// Claude Code come up as if signed out, so a session started on a non-default
  /// account would have opened on no account at all. See `ClaudeConfigFolder.path`.
  private static func accountLines(for agent: Agent) -> [String] {
    switch agent {
    case .claude(let folder) where folder.isDefault:
      ["unset CLAUDE_CONFIG_DIR"]
    case .claude(let folder):
      ["export CLAUDE_CONFIG_DIR=\(quoted(folder.path))"]
    case .codex(let home):
      ["export CODEX_HOME=\(quoted(home.path))"]
    }
  }

  /// Write the script where the terminal can reach it, named after the project.
  ///
  /// **One directory per launch, named after the project inside it.** Terminal titles
  /// a window with the document it opened, so the file's name is what the person sees
  /// in their window list for the first moment — `armada-3f2a.command` says nothing and
  /// `bastion.command` says where they are. A directory of its own is what lets two
  /// launches in the same project keep that name instead of colliding.
  ///
  /// `temporaryDirectory` is Armada's own, which the system cleans; the prune is for
  /// the machine that never restarts.
  private static func write(script: String, for project: URL) throws -> URL {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appending(
      path: "new-sessions", directoryHint: .isDirectory)
    prune(root)
    let directory = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

    // A project called `../..` or one with a slash in its name cannot be, but the
    // filename is built from user data and this costs one line.
    let name = project.lastPathComponent.replacingOccurrences(of: "/", with: "-")
    let url = directory.appending(
      path: (name.isEmpty ? "session" : name) + ".command", directoryHint: .notDirectory)
    try script.write(to: url, atomically: true, encoding: .utf8)
    // Terminal refuses to run a file that is not executable, and opens it in a text
    // editor instead — which is the failure this line exists to prevent.
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
  }

  /// Drop launch directories older than a day. Best-effort throughout: a script that
  /// cannot be removed is a few hundred bytes in a temporary directory.
  private static func prune(_ root: URL) {
    let fileManager = FileManager.default
    let cutoff = Date().addingTimeInterval(-24 * 60 * 60)
    let contents =
      (try? fileManager.contentsOfDirectory(
        at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
    for url in contents {
      let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
        .contentModificationDate
      guard let modified, modified < cutoff else { continue }
      try? fileManager.removeItem(at: url)
    }
  }

  /// A path as a single-quoted shell word, with any quote of its own escaped.
  ///
  /// Single quotes rather than double: inside them the shell expands nothing, so a
  /// folder named `$HOME` or `a(b)` is a folder and not an expansion. The one
  /// character that needs care is the quote itself, which is closed, escaped and
  /// reopened — the standard `'\''` dance.
  private static func quoted(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }
}

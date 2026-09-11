import Foundation

/// The one seam for `~/.claude`.
///
/// Every other file takes one of these rather than hardcoding a path, so the
/// multi-account case becomes a one-call-site change instead of a rewrite.
/// Nothing here writes: this prototype only reads the user's Claude config, and
/// `docs/design.md` puts credential and settings handling firmly out of scope.
struct ClaudeConfigFolder: Sendable, Hashable {
  /// The config folder itself — `~/.claude` by default, or `CLAUDE_CONFIG_DIR`.
  let base: URL

  /// Where the usage cache lives.
  ///
  /// A stored property rather than something derived from `base`, because the
  /// rule is not the obvious one. Measured on this machine on 2026-09-11, with a
  /// real second account in `~/.claude-skitrust`:
  ///
  /// - default folder `~/.claude` → `~/.claude.json`, a **sibling** of the folder
  /// - `CLAUDE_CONFIG_DIR=~/.claude-skitrust` → `~/.claude-skitrust/.claude.json`,
  ///   **inside** it (and there is no `~/.claude-skitrust.json`)
  ///
  /// `docs/limits-accounts-and-terms.md` listed this as unverified. It is not any
  /// longer, but the asymmetry is exactly the kind of thing that would be wrong if
  /// derived from `base` by a rule that looked reasonable.
  let usageJSON: URL

  /// The folder this launch should watch.
  ///
  /// Honours `CLAUDE_CONFIG_DIR` when it is set, which is how the env-vars docs
  /// say to run several accounts side by side. Note that a GUI launch does not
  /// inherit a shell's environment, so in practice this is the default folder
  /// unless Armada was started from a terminal that had the variable set.
  ///
  /// Watching *several* folders at once is the real multi-account feature and is
  /// not built: `docs/design.md` has it in v1 proper, and it needs an account
  /// column in the sessions list and one `UsageTracker` per folder rather than a
  /// second path here.
  static func resolved(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> ClaudeConfigFolder {
    if let custom = environment["CLAUDE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespaces),
      !custom.isEmpty
    {
      let base = URL(
        filePath: (custom as NSString).expandingTildeInPath, directoryHint: .isDirectory)
      return ClaudeConfigFolder(
        base: base,
        usageJSON: base.appending(path: ".claude.json", directoryHint: .notDirectory)
      )
    }
    return ClaudeConfigFolder(
      base: home.appending(path: ".claude", directoryHint: .isDirectory),
      usageJSON: home.appending(path: ".claude.json", directoryHint: .notDirectory)
    )
  }

  static let `default` = ClaudeConfigFolder.resolved()

  /// One JSON file per live session, named by pid. Prunes itself.
  var sessionsDir: URL { base.appending(path: "sessions", directoryHint: .isDirectory) }

  /// One directory per encoded cwd, each holding `<sessionId>.jsonl` transcripts.
  var projectsDir: URL { base.appending(path: "projects", directoryHint: .isDirectory) }
}

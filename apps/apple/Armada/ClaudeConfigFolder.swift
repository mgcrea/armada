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

  /// Every Claude config folder on this Mac.
  ///
  /// There is no registry of these, so this is a convention scan: `~/.claude`
  /// plus any `~/.claude-<name>` sibling, which is the shape the env-vars docs
  /// use for running several accounts side by side
  /// (`CLAUDE_CONFIG_DIR=~/.claude-work`). Anything `CLAUDE_CONFIG_DIR` points at
  /// is included too, even outside the home directory, so a folder that does not
  /// follow the convention still appears.
  ///
  /// Two filters earn their place. **Directories only** — `~/.claude.json` and
  /// its three `.backup` siblings match the same glob and are files. And a
  /// directory must actually hold a `sessions/`, so an unrelated `~/.claude-old`
  /// tarball extraction does not become an account row.
  ///
  /// Sorted with the default folder first, then alphabetically, so the list does
  /// not reorder itself between launches.
  static func discoverAll(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [ClaudeConfigFolder] {
    let fileManager = FileManager.default
    var found: [ClaudeConfigFolder] = []
    var seen: Set<String> = []

    func consider(_ folder: ClaudeConfigFolder) {
      let key = folder.base.standardizedFileURL.path(percentEncoded: false)
      guard !seen.contains(key) else { return }
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: key, isDirectory: &isDirectory), isDirectory.boolValue
      else { return }
      let sessions = folder.sessionsDir.path(percentEncoded: false)
      guard fileManager.fileExists(atPath: sessions) else { return }
      seen.insert(key)
      found.append(folder)
    }

    // The default folder, whose usage cache sits beside it rather than inside.
    consider(
      ClaudeConfigFolder(
        base: home.appending(path: ".claude", directoryHint: .isDirectory),
        usageJSON: home.appending(path: ".claude.json", directoryHint: .notDirectory)))

    let siblings =
      (try? fileManager.contentsOfDirectory(atPath: home.path(percentEncoded: false))) ?? []
    for name in siblings.sorted() where name.hasPrefix(".claude-") {
      let base = home.appending(path: name, directoryHint: .isDirectory)
      consider(
        ClaudeConfigFolder(
          base: base,
          usageJSON: base.appending(path: ".claude.json", directoryHint: .notDirectory)))
    }

    // Whatever this process was told to use, wherever it lives.
    consider(resolved(environment: environment, home: home))

    return found
  }

  /// The folder Claude Code uses when `CLAUDE_CONFIG_DIR` is **unset**.
  ///
  /// Load-bearing for `UsageProbe`, which has to decide whether to set that variable
  /// on the `claude` it spawns. Setting it to this folder's own path is not a no-op:
  /// a custom folder keeps its account file *inside* it, so `CLAUDE_CONFIG_DIR` sends
  /// Claude Code looking for `~/.claude/.claude.json` — which does not exist, because
  /// the default folder's lives *beside* it. Measured 2026-09-12: the probe then
  /// comes back `subscription_type: null, rate_limits_available: false`, as if signed
  /// out. Told apart by the same asymmetry `usageJSON` exists to record.
  ///
  /// Derived from the pairing rather than from the folder's name, so a
  /// `CLAUDE_CONFIG_DIR` that happens to end in `.claude` is not mistaken for it.
  var isDefault: Bool {
    usageJSON.deletingLastPathComponent().standardizedFileURL.path(percentEncoded: false)
      != base.standardizedFileURL.path(percentEncoded: false)
  }

  /// One JSON file per live session, named by pid. Prunes itself.
  var sessionsDir: URL { base.appending(path: "sessions", directoryHint: .isDirectory) }

  /// One directory per encoded cwd, each holding `<sessionId>.jsonl` transcripts.
  var projectsDir: URL { base.appending(path: "projects", directoryHint: .isDirectory) }
}

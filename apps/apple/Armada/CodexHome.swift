import Foundation

/// The one seam for `~/.codex`, mirroring `ClaudeConfigFolder`.
///
/// Codex's layout is the same idea as Claude Code's and almost none of the same
/// shapes, which is the whole reason this is a separate type rather than a second
/// case inside the Claude one:
///
/// | | Claude Code | Codex |
/// | --- | --- | --- |
/// | live sessions | `sessions/<pid>.json`, a registry | no registry — a flock in `thread-writer-locks/` |
/// | transcripts | `projects/<enc-cwd>/<sessionId>.jsonl` | `sessions/YYYY/MM/DD/rollout-<ts>-<id>.jsonl` |
/// | titles | `ai-title` entries inside the transcript | `session_index.jsonl`, a separate file |
/// | plan limits | `cachedUsageUtilization` in one JSON document | a `token_count` event inside every rollout |
/// | turn boundaries | inferred from an unanswered `tool_use` | `task_started` / `task_complete`, explicit |
///
/// Nothing here writes. `auth.json` sits in this folder and is never opened: it
/// holds an API key and OAuth tokens, and Armada has no business reading either.
/// The plan name arrives free with the rate limits (`plan_type: "plus"`), so
/// there is nothing in the credential file this app would even want.
/// `nonisolated` is load-bearing, for the same reason it is on `TranscriptTitle`:
/// under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` every member here would
/// otherwise be main-actor isolated, and `CodexWatcher.scan` — which runs off the
/// main actor precisely so that reading a few megabytes of rollout does not stall
/// the window — could not so much as ask for a path.
nonisolated struct CodexHome: Sendable, Hashable {
  /// The home itself — `~/.codex` by default, or `CODEX_HOME`.
  let base: URL

  /// Derived rather than stored, unlike `ClaudeConfigFolder.usageJSON`: Codex has
  /// no asymmetry to encode. Everything lives inside the home, for the default
  /// folder and a custom one alike.
  var sessionsDir: URL { base.appending(path: "sessions", directoryHint: .isDirectory) }

  /// `<sessionId>.lock`, one per session that a Codex process currently owns.
  /// See `CodexLocks`.
  var locksDir: URL {
    base.appending(path: "thread-writer-locks", directoryHint: .isDirectory)
  }

  /// Rollouts Codex has moved out of `sessions/`, flat rather than by day. Only the usage
  /// index reads here; a moved rollout keeps its file name and so its session id.
  var archivedSessionsDir: URL {
    base.appending(path: "archived_sessions", directoryHint: .isDirectory)
  }

  /// `{"id", "thread_name", "updated_at"}` per line. See `CodexTitleIndex`.
  var sessionIndex: URL {
    base.appending(path: "session_index.jsonl", directoryHint: .notDirectory)
  }

  /// The home this launch should watch.
  ///
  /// `CODEX_HOME` is Codex's equivalent of `CLAUDE_CONFIG_DIR`, and carries the
  /// same caveat: a GUI launch inherits no shell environment, so in practice this
  /// is `~/.codex` unless Armada was started from a terminal that had it set.
  static func resolved(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> CodexHome {
    if let custom = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespaces),
      !custom.isEmpty
    {
      return CodexHome(
        base: URL(filePath: (custom as NSString).expandingTildeInPath, directoryHint: .isDirectory))
    }
    return CodexHome(base: home.appending(path: ".codex", directoryHint: .isDirectory))
  }

  /// Every Codex home on this Mac.
  ///
  /// Deliberately *not* the convention scan `ClaudeConfigFolder.discoverAll` does.
  /// Claude Code's own docs name the `~/.claude-<name>` sibling pattern and give it
  /// as the way to run several accounts, so scanning for it finds real accounts.
  /// Codex documents `CODEX_HOME` with no naming convention at all
  /// (`docs/codex-sessions.md`), so a `~/.codex-*` scan would be inventing one —
  /// and inventing one is how you get a row for somebody's backup directory.
  ///
  /// So: the default home, plus whatever `CODEX_HOME` points at, plus the homes somebody
  /// added through Armada (`AddedHomes`), which are named rather than guessed. A home counts
  /// only if it has a `sessions/`, which is what separates a real home from a folder that
  /// merely has the name.
  ///
  /// **An added home also counts with only `version.json`.** Codex writes that at its first
  /// launch and `sessions/` only once a session runs (measured 2026-09-17 on 0.154), so a home
  /// somebody has just signed in to would otherwise stay missing until they used it. The
  /// looser rule is for added homes alone: they were named by the person, so a stray
  /// `version.json` in a folder of the right name is not a risk there.
  static func discoverAll(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser,
    added: [String] = AddedHomes.paths(for: .codex)
  ) -> [CodexHome] {
    let fileManager = FileManager.default
    var found: [CodexHome] = []
    var seen: Set<String> = []

    func consider(_ candidate: CodexHome, versionIsEnough: Bool = false) {
      let key = candidate.base.standardizedFileURL.path(percentEncoded: false)
      guard !seen.contains(key) else { return }
      let marker = versionIsEnough ? candidate.versionJSON : nil
      guard
        fileManager.fileExists(atPath: candidate.sessionsDir.path(percentEncoded: false))
          || marker.map({ fileManager.fileExists(atPath: $0.path(percentEncoded: false)) }) == true
      else { return }
      seen.insert(key)
      found.append(candidate)
    }

    consider(CodexHome(base: home.appending(path: ".codex", directoryHint: .isDirectory)))
    consider(resolved(environment: environment, home: home))
    for path in added {
      consider(
        CodexHome(base: URL(filePath: path, directoryHint: .isDirectory)), versionIsEnough: true)
    }
    return found
  }

  /// Written by Codex at its first launch, before any session. See `discoverAll`.
  var versionJSON: URL { base.appending(path: "version.json", directoryHint: .notDirectory) }

  /// The path without a trailing slash — the persisted sidebar selection, and what
  /// `CODEX_HOME` is set to for anything Armada starts.
  ///
  /// Codex has not been measured to care about the slash the way Claude Code does
  /// (`ClaudeConfigFolder.path` records that measurement: a trailing slash there makes
  /// the account report no limits at all). It is spelled the same way here anyway —
  /// the cost is nothing, and a vendor that tolerates it today is not a vendor that
  /// promised to.
  var path: String {
    let raw = base.standardizedFileURL.path(percentEncoded: false)
    return raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
  }

  var id: String { path }

  /// `~/.codex` reads as "Codex"; anything else keeps its folder name.
  var displayName: String {
    let last = base.lastPathComponent
    return last == ".codex" ? "Codex" : String(last.dropFirst())
  }

  var displayPath: String {
    (base.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }

  /// The day directories a scan should look in, newest first.
  ///
  /// Rollouts are filed under `sessions/YYYY/MM/DD` by **local** date — measured:
  /// a session whose first event is `2026-09-11T05:01:34Z` is filed under
  /// `2026/09/11` on a UTC+2 machine, matching the `T07-01-34` in its own filename.
  /// So the directories are built from the local calendar, not from UTC.
  ///
  /// Enumerating the tree instead would work today and get slower every month:
  /// this Mac has 418 rollouts across six months of directories, and nothing
  /// prunes them.
  func dayDirectories(back days: Int, from now: Date = .now) -> [URL] {
    let calendar = Calendar.current
    return (0...max(0, days)).compactMap { offset -> URL? in
      guard let date = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
      let parts = calendar.dateComponents([.year, .month, .day], from: date)
      guard let year = parts.year, let month = parts.month, let day = parts.day else { return nil }
      let path = String(format: "%04d/%02d/%02d", year, month, day)
      let url = sessionsDir.appending(path: path, directoryHint: .isDirectory)
      return FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) ? url : nil
    }
  }
}

import Foundation

/// The one seam for `~/.grok`, mirroring `CodexHome`.
///
/// | | Claude Code | Codex | Grok Build |
/// | --- | --- | --- | --- |
/// | live sessions | `sessions/<pid>.json` | a flock in `thread-writer-locks/` | `active_sessions.json`, TUI sessions only, with a pid |
/// | transcripts | `projects/<enc-cwd>/<id>.jsonl` | `sessions/YYYY/MM/DD/rollout-*.jsonl` | `sessions/<enc-cwd>/<id>/updates.jsonl` |
/// | titles | `ai-title` entries | `session_index.jsonl` | `generated_title` in the session's `summary.json` |
/// | plan limits | `cachedUsageUtilization` | `token_count` events | none on disk |
/// | turn boundaries | inferred | `task_complete` | `turn_completed` |
///
/// Nothing here writes, and `auth.json` is never opened, for `CodexHome`'s reason. Measured
/// against grok 1.0.34 on 2026-09-17; see docs/grok-sessions.md.
nonisolated struct GrokHome: Sendable, Hashable {
  /// `~/.grok` by default, or `GROK_HOME`.
  let base: URL

  var sessionsDir: URL { base.appending(path: "sessions", directoryHint: .isDirectory) }

  /// `[{session_id, pid, cwd, opened_at}]`. Lists open TUI sessions; a headless `grok -p` run
  /// never appears in it.
  var activeSessions: URL {
    base.appending(path: "active_sessions.json", directoryHint: .notDirectory)
  }

  /// The home this launch should watch. `GROK_HOME` carries `CODEX_HOME`'s caveat: a GUI
  /// launch inherits no shell environment.
  static func resolved(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> GrokHome {
    if let custom = environment["GROK_HOME"]?.trimmingCharacters(in: .whitespaces),
      !custom.isEmpty
    {
      return GrokHome(
        base: URL(filePath: (custom as NSString).expandingTildeInPath, directoryHint: .isDirectory))
    }
    return GrokHome(base: home.appending(path: ".grok", directoryHint: .isDirectory))
  }

  /// The default home plus whatever `GROK_HOME` points at, each counted only when it is xAI's.
  ///
  /// **Another tool uses the same folder.** The community `superagent-ai/grok-cli` also
  /// installs a `grok` binary and keeps `~/.grok/user-settings.json`. xAI's home has
  /// `version.json` or `config.toml`, and a `sessions/` to read.
  static func discoverAll(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> [GrokHome] {
    var found: [GrokHome] = []
    var seen: Set<String> = []
    for candidate in [
      GrokHome(base: home.appending(path: ".grok", directoryHint: .isDirectory)),
      resolved(environment: environment, home: home),
    ] {
      let key = candidate.path
      guard !seen.contains(key), candidate.isGrokBuild else { continue }
      seen.insert(key)
      found.append(candidate)
    }
    return found
  }

  var isGrokBuild: Bool {
    let fileManager = FileManager.default
    func exists(_ name: String) -> Bool {
      fileManager.fileExists(atPath: base.appending(path: name).path(percentEncoded: false))
    }
    return (exists("version.json") || exists("config.toml"))
      && fileManager.fileExists(atPath: sessionsDir.path(percentEncoded: false))
  }

  /// No trailing slash, as `CodexHome.path` spells it.
  var path: String {
    let raw = base.standardizedFileURL.path(percentEncoded: false)
    return raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
  }

  var id: String { path }

  /// `~/.grok` reads as "Grok Build"; anything else keeps its folder name.
  var displayName: String {
    let last = base.lastPathComponent
    return last == ".grok" ? "Grok Build" : String(last.drop { $0 == "." })
  }

  var displayPath: String {
    (base.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }
}

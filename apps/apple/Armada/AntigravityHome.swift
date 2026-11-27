import Foundation

/// The one seam for `~/.gemini/antigravity-cli`, mirroring `GrokHome`.
///
/// | | Grok Build | Antigravity CLI |
/// | --- | --- | --- |
/// | live sessions | `active_sessions.json`, with a pid | a `presence/<id>.lock` an `agy` process holds open |
/// | run state | inferred from `updates.jsonl` | `status` in `conversation_summaries.db` |
/// | transcripts | `sessions/<enc-cwd>/<id>/updates.jsonl` | `brain/<id>/.system_generated/logs/transcript.jsonl` |
/// | titles | `generated_title` in `summary.json` | `title` in `conversation_summaries.db`, TUI sessions only |
/// | plan limits | `grok agent stdio` | none on disk |
///
/// One home only: `agy` has no home variable, and `~/.gemini` is shared with Gemini CLI, so
/// the folder counts only once `conversation_summaries.db` is in it. Nothing here writes, and
/// the encrypted `*.pb` files and `conversations/<id>.db` are never opened. Measured against
/// the Antigravity CLI 1.5.18 on 2026-11-27; see docs/antigravity-sessions.md.
nonisolated struct AntigravityHome: Sendable, Hashable {
  /// `~/.gemini/antigravity-cli`.
  let base: URL

  /// One row per conversation: the index, SQLite in WAL mode, written by every `agy` process.
  var summariesDB: URL {
    base.appending(path: "conversation_summaries.db", directoryHint: .notDirectory)
  }

  /// `<id>.lock`, zero bytes, held open while a process owns the conversation.
  var presenceDir: URL { base.appending(path: "presence", directoryHint: .isDirectory) }

  var brainDir: URL { base.appending(path: "brain", directoryHint: .isDirectory) }

  /// The readable transcript, one JSON object per step.
  func transcript(id: String) -> URL {
    brainDir.appending(
      path: "\(id)/.system_generated/logs/transcript.jsonl", directoryHint: .notDirectory)
  }

  /// The home, once `agy` has written its index there; nil before its first conversation.
  static func discover(
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> AntigravityHome? {
    let candidate = AntigravityHome(
      base: home.appending(path: ".gemini/antigravity-cli", directoryHint: .isDirectory))
    return FileManager.default.fileExists(
      atPath: candidate.summariesDB.path(percentEncoded: false))
      ? candidate : nil
  }

  /// No trailing slash, as `GrokHome.path` spells it.
  var path: String {
    let raw = base.standardizedFileURL.path(percentEncoded: false)
    return raw.count > 1 && raw.hasSuffix("/") ? String(raw.dropLast()) : raw
  }

  var id: String { path }

  var displayName: String { "Antigravity" }

  var displayPath: String {
    (base.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
  }
}

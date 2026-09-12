import Foundation

/// What a Claude Code session loads in a given project before anyone prompts it,
/// broken down the way `/context` breaks it down.
///
/// **This is the one thing a transcript cannot say.** `TranscriptContext` reads a
/// session's context exactly, but only as a total: the split into system prompt,
/// tools, memory files and skills is computed in the running process and never
/// written to disk. `get_context_usage` returns that split — including `memoryFiles`
/// with a path and a token count per file — and a headless `claude` answers it.
///
/// **It describes a comparable session, not the watched one.** The probe is a fresh
/// process, so `messageBreakdown` comes back all zeros: it reports what a session
/// started *here, now* would load, not what the session in the list actually loaded.
/// The two differ whenever that session changed model, connected different MCP
/// servers, or loaded a skill part-way through — and on 2026-09-12 two probes minutes
/// apart differed by an entire `MCP tools (deferred)` category. So the UI presents
/// these as their own group with their own total, never as a partition of the
/// session's measured opening figure.
///
/// **Spawned per answer, never held open.** See `ClaudeControl` for the measurements
/// behind that; the short version is 206MB and three child processes for a figure
/// that does not change until the config does.
nonisolated struct ContextComposition: Sendable, Hashable {
  /// The categories, already filtered to the ones that occupy the window.
  let categories: [ContextCategoryReading]
  /// Every memory file that would load here, with its own size.
  let memoryFiles: [MemoryFile]
  /// What the probe's own prompt came to — the sum of the categories below, and the
  /// figure comparable to a session's "Loaded at start".
  let total: Int
  let measuredAt: Date

  nonisolated struct ContextCategoryReading: Sendable, Hashable, Identifiable {
    let name: String
    let tokens: Int
    var id: String { name }
  }

  nonisolated struct MemoryFile: Sendable, Hashable, Identifiable {
    let path: String
    let tokens: Int
    var id: String { path }

    /// `~/.claude/CLAUDE.md` rather than the whole absolute path, which is too long
    /// for the panel and mostly the user's own home directory repeated.
    var displayPath: String {
      let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
      return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
  }
}

nonisolated enum ContextProbe {
  /// Categories that describe the window rather than occupy it.
  ///
  /// `Free space` is the remainder and `Autocompact buffer` is reserve, so neither
  /// belongs in a breakdown of what was *loaded*. The deferred pairs — `MCP tools
  /// (deferred)`, `System tools (deferred)` — are declared but not in the prompt, and
  /// Claude Code excludes them from its own `totalTokens` for that reason: one probe
  /// reported 222,156 deferred tokens against a 39,974 total. Counting them would put
  /// a session at a quarter of a million tokens before its first prompt.
  private static let excluded: Set<String> = [
    "Free space", "Autocompact buffer", "Compact buffer",
  ]

  /// Ask what a session in `cwd` under `folder` would load. Nil on any failure.
  static func run(folder: ClaudeConfigFolder, cwd: URL) -> ContextComposition? {
    guard
      let payload = ClaudeControl.request(
        // `summary` rather than the default `full`: `full` counts every category
        // through the `/v1/messages/count_tokens` endpoint, which is a network round
        // trip per category for a breakdown this already answers locally.
        subtype: "get_context_usage", extra: #","detail":"summary""#,
        folder: folder, cwd: cwd)
    else { return nil }

    let categories = (payload["categories"] as? [[String: Any]] ?? []).compactMap {
      entry -> ContextComposition.ContextCategoryReading? in
      guard let name = entry["name"] as? String, let tokens = entry["tokens"] as? Int,
        tokens > 0, !excluded.contains(name),
        // Belt and braces beside the name list: the payload also marks these.
        entry["isDeferred"] as? Bool != true, entry["kind"] as? String != "deferred"
      else { return nil }
      return .init(name: name, tokens: tokens)
    }
    guard !categories.isEmpty else { return nil }

    let memoryFiles = (payload["memoryFiles"] as? [[String: Any]] ?? []).compactMap {
      entry -> ContextComposition.MemoryFile? in
      guard let path = entry["path"] as? String, let tokens = entry["tokens"] as? Int
      else { return nil }
      return .init(path: path, tokens: tokens)
    }

    return ContextComposition(
      categories: categories.sorted { $0.tokens > $1.tokens },
      memoryFiles: memoryFiles.sorted { $0.tokens > $1.tokens },
      // The payload's own `totalTokens` already excludes the deferred categories, but
      // it is not summed here: this total must match the rows shown, and a future
      // build that changes what `excluded` drops would silently break that tie.
      total: categories.reduce(0) { $0 + $1.tokens },
      measuredAt: .now)
  }
}

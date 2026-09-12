import Foundation

/// Which Codex sessions a process currently owns.
///
/// **Codex has no session registry.** Claude Code writes `sessions/<pid>.json` for
/// every live session and Armada can ask the kernel whether that pid still exists.
/// Codex writes nothing of the kind, and its processes are the wrong shape for it
/// anyway: the three `codex … app-server` processes running on this Mac are hosts
/// for the VS Code extension, each able to hold several threads, so "is a codex
/// process alive" answers nothing about any particular session.
///
/// What it does write is `~/.codex/thread-writer-locks/<sessionId>.lock`. Measured
/// on 2026-09-11 by running `codex exec` and watching the directory:
///
/// - the file appears when the session starts writing its rollout and is **gone**
///   about two seconds after `task_complete`;
/// - it is **zero bytes** — the liveness is the flock, not the contents. `lsof`
///   showed `codex … 32u REG` holding it open, so there is no pid to read out of
///   it the way `sessions/<pid>.json` gives one;
/// - the name is the *session* id, matching the uuid in the rollout filename, so a
///   lock maps to a session with no file read at all.
///
/// **The lock spans the session, not the turn.** `codex exec` could not show this —
/// it exits with its turn, so a probe always sees both end together — but simply
/// looking at the directory while the ChatGPT VS Code panel had a thread open did:
/// one `codex` process held two locks, and the rollout for one of them had ended its
/// turn with `task_complete` 7h20m earlier. So a locked session whose turn is
/// finished is genuinely open and idle, which is what `CodexSessionState`
/// `.awaitingInput` says.
///
/// **A lock can exist with no rollout file**, for a session opened and never
/// prompted — the second of those two locks was exactly that. It follows that
/// walking `sessions/` does not enumerate open sessions, and `CodexWatcher` misses
/// that case today (`docs/implementation.md`, "Where the Codex spike is thin").
///
/// A crashed process leaves its lock behind, and nothing here can tell that from a
/// live one. With no pid in the file there is no `kill(pid, 0)` equivalent; the
/// honest alternative is `flock(LOCK_SH | LOCK_NB)`, which is *not* used, because
/// taking even a shared lock on a file Codex expects to hold exclusively could make
/// a real Codex session fail to start. Armada reads. A stale lock ages out of the
/// list on recency like anything else.
nonisolated enum CodexLocks {
  /// Codex's own coordination file, which is not a session.
  static let coordinationLock = ".coordination.lock"

  static func liveSessionIDs(in directory: URL) -> Set<String> {
    let names =
      (try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false)))
      ?? []
    var ids: Set<String> = []
    for name in names where name.hasSuffix(".lock") && name != coordinationLock {
      ids.insert(String(name.dropLast(".lock".count)))
    }
    return ids
  }
}

/// Session titles, which Codex keeps in a file of its own.
///
/// `~/.codex/session_index.jsonl`, one `{"id", "thread_name", "updated_at"}` per
/// line. This answers `docs/codex-sessions.md`'s first open question — "where does
/// Codex keep a session's title, if anywhere" — and it is a nicer answer than the
/// Claude side's: a 104KB index rather than a tail-scan of every 2MB transcript.
///
/// **It is not complete, and the gap is not random.** 9 of the 13 rollouts written
/// on this Mac on 2026-09-11 have an entry; the 4 without are all
/// `guardian_review` subagents, which are spawned rather than started by a person
/// and never get a generated name. So a missing title means "this thread was never
/// named", not "the index is behind".
///
/// **`state_5.sqlite` is the richer source and is deliberately not used.** Its
/// `threads` table has 819 rows carrying `title`, `cwd`, `archived`, `git_branch`
/// and more, and it reads fine read-only while the ChatGPT app holds it open. Two
/// reasons against it here: the filename carries a schema version that has already
/// been bumped five times, and its `title` column is not a title — it is empty for
/// every named automation thread and holds the *entire prompt* for the subagent
/// ones, over 100KB in a row. The plain-text index says less and says it reliably.
nonisolated enum CodexTitleIndex {
  static func read(_ url: URL) -> [String: String] {
    guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [:] }
    var titles: [String: String] = [:]
    for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
      guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        let id = object["id"] as? String,
        let name = object["thread_name"] as? String, !name.isEmpty
      else { continue }
      // Last line wins: the file is append-ordered and a renamed thread is
      // rewritten rather than edited in place.
      titles[id] = name
    }
    return titles
  }
}
